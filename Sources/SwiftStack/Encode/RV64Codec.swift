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
    public static let stimecmp   = RVCSR(unchecked: 0x14D)
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
    public static let hstatus    = RVCSR(unchecked: 0x600)
    public static let hgatp      = RVCSR(unchecked: 0x680)
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

    /// Symbolic CSR names accepted by the assembler and printed by the disassembler: unprivileged FP,
    /// vector and counter CSRs (Zicntr, Zihpm), S-mode (Sstc, Ssstateen, Sscofpmf), H and VS-mode (Sha),
    /// the M-mode CSRs, and every other name LLVM MC prints for RV64 (so the disassembly matches it; any other
    /// CSR prints as a decimal number). The withdrawn N extension's `u*` CSRs (LLVM MC rejects them), the
    /// RV32-only `*h` halves, and the RV32-only odd `pmpcfgN` are deliberately not named.
    public static let namedCSRs: [(name: String, csr: RVCSR)] = {
        var list: [(String, UInt16)] = [
            ("fflags", 0x001), ("frm", 0x002), ("fcsr", 0x003),
            ("vstart", 0x008), ("vxsat", 0x009), ("vxrm", 0x00A), ("vcsr", 0x00F),
            ("sstatus", 0x100), ("sie", 0x104), ("stvec", 0x105), ("scounteren", 0x106), ("senvcfg", 0x10A),
            ("sstateen0", 0x10C), ("sstateen1", 0x10D), ("sstateen2", 0x10E), ("sstateen3", 0x10F),
            ("sscratch", 0x140), ("sepc", 0x141), ("scause", 0x142), ("stval", 0x143), ("sip", 0x144),
            ("stimecmp", 0x14D), ("siselect", 0x150), ("sireg", 0x151), ("stopei", 0x15C), ("satp", 0x180),
            ("vsstatus", 0x200), ("vsie", 0x204), ("vstvec", 0x205), ("vsscratch", 0x240), ("vsepc", 0x241),
            ("vscause", 0x242), ("vstval", 0x243), ("vsip", 0x244), ("vstimecmp", 0x24D), ("vsatp", 0x280),
            ("mstatus", 0x300), ("misa", 0x301), ("medeleg", 0x302), ("mideleg", 0x303), ("mie", 0x304),
            ("mtvec", 0x305), ("mcounteren", 0x306), ("menvcfg", 0x30A),
            ("mstateen0", 0x30C), ("mstateen1", 0x30D), ("mstateen2", 0x30E), ("mstateen3", 0x30F),
            ("mcountinhibit", 0x320), ("mscratch", 0x340), ("mepc", 0x341), ("mcause", 0x342), ("mtval", 0x343),
            ("mip", 0x344), ("mtinst", 0x34A), ("mtval2", 0x34B),
            ("hstatus", 0x600), ("hedeleg", 0x602), ("hideleg", 0x603), ("hie", 0x604), ("htimedelta", 0x605),
            ("hcounteren", 0x606), ("hgeie", 0x607), ("henvcfg", 0x60A),
            ("hstateen0", 0x60C), ("hstateen1", 0x60D), ("hstateen2", 0x60E), ("hstateen3", 0x60F),
            ("htval", 0x643), ("hip", 0x644), ("hvip", 0x645), ("htinst", 0x64A), ("hgatp", 0x680),
            ("mseccfg", 0x747), ("mcycle", 0xB00), ("minstret", 0xB02),
            ("cycle", 0xC00), ("time", 0xC01), ("instret", 0xC02),
            ("vl", 0xC20), ("vtype", 0xC21), ("vlenb", 0xC22),
            ("scountovf", 0xDA0), ("hgeip", 0xE12),
            ("mvendorid", 0xF11), ("marchid", 0xF12), ("mimpid", 0xF13), ("mhartid", 0xF14), ("mconfigptr", 0xF15),
            // Zicfiss, Zkr, Zcmt; Smcntrpmf, Smctr/Ssctr, Smaia/Ssaia (indirect access, interrupt filtering), Ssqosid,
            // Smrnmi, Sdtrig and Sdext: names LLVM MC also prints.
            ("ssp", 0x011), ("seed", 0x015), ("jvt", 0x017), ("scountinhibit", 0x120),
            ("sctrctl", 0x14E), ("sctrstatus", 0x14F), ("sctrdepth", 0x15F), ("vsctrctl", 0x24E), ("mctrctl", 0x34E),
            ("sireg2", 0x152), ("sireg3", 0x153), ("sireg4", 0x155), ("sireg5", 0x156), ("sireg6", 0x157),
            ("srmcfg", 0x181), ("vsiselect", 0x250), ("vsireg", 0x251), ("vsireg2", 0x252), ("vsireg3", 0x253),
            ("vsireg4", 0x255), ("vsireg5", 0x256), ("vsireg6", 0x257), ("vstopei", 0x25C),
            ("mvien", 0x308), ("mvip", 0x309), ("mcyclecfg", 0x321), ("minstretcfg", 0x322),
            ("miselect", 0x350), ("mireg", 0x351), ("mireg2", 0x352), ("mireg3", 0x353), ("mireg4", 0x355),
            ("mireg5", 0x356), ("mireg6", 0x357), ("mtopei", 0x35C), ("scontext", 0x5A8),
            ("hvien", 0x608), ("hvictl", 0x609), ("hviprio1", 0x646), ("hviprio2", 0x647), ("hcontext", 0x6A8),
            ("mnscratch", 0x740), ("mnepc", 0x741), ("mncause", 0x742), ("mnstatus", 0x744),
            ("tselect", 0x7A0), ("tdata1", 0x7A1), ("tdata2", 0x7A2), ("tdata3", 0x7A3), ("tinfo", 0x7A4),
            ("tcontrol", 0x7A5), ("mcontext", 0x7A8), ("mscontext", 0x7AA),
            ("dcsr", 0x7B0), ("dpc", 0x7B1), ("dscratch0", 0x7B2), ("dscratch1", 0x7B3),
            ("stopi", 0xDB0), ("vstopi", 0xEB0), ("mtopi", 0xFB0),
        ]
        for n in 3...31 {
            list.append(("hpmcounter\(n)", UInt16(0xC00 + n)))
            list.append(("mhpmcounter\(n)", UInt16(0xB00 + n)))
            list.append(("mhpmevent\(n)", UInt16(0x320 + n)))
        }
        for n in stride(from: 0, through: 14, by: 2) {
            list.append(("pmpcfg\(n)", UInt16(0x3A0 + n)))
        }
        for n in 0...63 {
            list.append(("pmpaddr\(n)", UInt16(0x3B0 + n)))
        }
        return list.map { (name: $0.0, csr: RVCSR(unchecked: $0.1)) }
    }()

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
        return "\(rawValue)" // LLVM MC prints an unnamed CSR in decimal
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

    /// `e<sew>, m<lmul>, t<a|u>, m<a|u>`, or the raw number (as LLVM MC prints it) when any reserved
    /// field is set (`vsew >= 4`, `vlmul == 4`, or bits 8 and above), since the symbolic form cannot carry those bits.
    public var description: String {
        let vlmul = rawValue & 0x7
        let vsew = (rawValue >> 3) & 0x7
        let vta = (rawValue >> 6) & 0x1
        let vma = (rawValue >> 7) & 0x1
        if (rawValue >> 8) != 0 {
            return String(rawValue)
        }

        let sewStr: String
        switch vsew {
        case 0b000: sewStr = "e8"
        case 0b001: sewStr = "e16"
        case 0b010: sewStr = "e32"
        case 0b011: sewStr = "e64"
        default: return String(rawValue)
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
        default: return String(rawValue)
        }

        let taStr = vta != 0 ? "ta" : "tu"
        let maStr = vma != 0 ? "ma" : "mu"
        return "\(sewStr), \(lmulStr), \(taStr), \(maStr)"
    }
}

/// Hardware instruction encoding format used by `RV64InstructionTable`.
///
/// A format fixes which `RV64Instruction` fields map to which instruction bits and how the operands are
/// printed and parsed. Bits that a descriptor's `mask` covers are fixed by its `match` and are never taken
/// from the instruction value (for example the `vm` bit of `vmv.v.v`, or the `vs1` field of `vzext.vf2`).
/// RVV formats share one field layout: `vd`/`vs3`/`rd` in `rd` [11:7], `vs1`/`rs1`/`fs1`/`imm5` in `rs1`
/// [19:15], `vs2`/`rs2` (stride or index) in `rs2` [24:20], and `vm` [25] (`false` = masked by `v0.t`).
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
    case rFMA       // rs3(f)[31:27] | fmt[26:25] | rs2(f)[24:20] | rs1(f)[19:15] | rm[14:12] | rd(f)[11:7] | opcode[6:0]
    case rFPFixed   // funct7[31:25] | rs2(f)[24:20] | rs1(f)[19:15] | funct3[14:12] | rd(f)[11:7] | opcode[6:0]
    case rFPUnary   // funct7[31:25] | fixed_rs2[24:20] | rs1(f)[19:15] | rm[14:12] | rd(f)[11:7] | opcode[6:0]
    case rFPCmp     // funct7[31:25] | rs2(f)[24:20] | rs1(f)[19:15] | funct3[14:12] | rd(x)[11:7] | opcode[6:0]
    case rFPCvtF2I  // funct7[31:25] | fixed_rs2[24:20] | rs1(f)[19:15] | rm[14:12] | rd(x)[11:7] | opcode[6:0]
    case rFPCvtMod  // fcvtmod.w.d: as rFPCvtF2I with rm fixed to `rtz` (always printed)
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
    case fence      // fm[31:28]=0000 | pred[27:24] | succ[23:20] | 00000 | 000 | 00000 | 0001111 (imm = pred << 4 | succ)
    case csrReg     // csr[31:20] | rs1[19:15] | funct3[14:12] | rd[11:7] | 1110011
    case csrImm     // csr[31:20] | uimm5[19:15] | funct3[14:12] | rd[11:7] | 1110011
    case systemFixed// fixed 32-bit encoding (ecall, ebreak, fence.i, fence.tso, pause, ntl.*, wrs.*, sret, mret, wfi, ...)
    case sfenceVMA  // funct7[31:25] | rs2[24:20] | rs1[19:15] | 000[14:12] | 00000[11:7] | 1110011 (sfence.vma, sinval.vma, hfence.*, hinval.*)
    case cbo        // Zicbom/Zicboz: funct12[31:20] | (rs1)[19:15] | 010[14:12] | 00000[11:7] | 0001111
    case prefetch   // Zicbop: imm[11:5][31:25] | funct5[24:20] | (rs1)[19:15] | 110[14:12] | 00000[11:7] | 0010011
    case hlv        // H: funct7[31:25] | funct5[24:20] | (rs1)[19:15] | 100[14:12] | rd[11:7] | 1110011
    case hsv        // H: funct7[31:25] | rs2[24:20] | (rs1)[19:15] | 100[14:12] | 00000[11:7] | 1110011

    // RVV 1.0 32-bit formats
    case vsetvli    // 0[31] | zimm11[30:20] | rs1[19:15] | 111[14:12] | rd[11:7] | 1010111
    case vsetivli   // 11[31:30] | zimm10[29:20] | uimm5[19:15] | 111[14:12] | rd[11:7] | 1010111
    case vsetvl     // 1000000[31:25] | rs2[24:20] | rs1[19:15] | 111[14:12] | rd[11:7] | 1010111
    case vLoadUnit  // nf | mew | 00 | vm | lumop[24:20] | rs1 | width | vd | 0000111       `vd, (rs1)[, v0.t]`
    case vStoreUnit // nf | mew | 00 | vm | sumop[24:20] | rs1 | width | vs3 | 0100111      `vs3, (rs1)[, v0.t]`
    case vLoadStrided  // nf | mew | 10 | vm | rs2 | rs1 | width | vd | 0000111           `vd, (rs1), rs2[, v0.t]`
    case vStoreStrided // nf | mew | 10 | vm | rs2 | rs1 | width | vs3 | 0100111          `vs3, (rs1), rs2[, v0.t]`
    case vLoadIndexed  // nf | mew | x1 | vm | vs2 | rs1 | width | vd | 0000111           `vd, (rs1), vs2[, v0.t]`
    case vStoreIndexed // nf | mew | x1 | vm | vs2 | rs1 | width | vs3 | 0100111          `vs3, (rs1), vs2[, v0.t]`
    case vLoadWhole // nf | 0 | 00 | 1 | 01000 | rs1 | width | vd | 0000111                `vd, (rs1)`
    case vStoreWhole// nf | 0 | 00 | 1 | 01000 | rs1 | 000 | vs3 | 0100111                 `vs3, (rs1)`
    case vVV        // funct6 | vm | vs2 | vs1 | funct3 | vd | 1010111     `vd, vs2, vs1[, v0.t | , v0]` (.vv .wv .vs .mm .vvm)
    case vVX        // funct6 | vm | vs2 | rs1 | funct3 | vd | 1010111     `vd, vs2, rs1[, ...]`
    case vVF        // funct6 | vm | vs2 | fs1 | funct3 | vd | 1010111     `vd, vs2, fs1[, ...]`
    case vVI        // funct6 | vm | vs2 | simm5 | funct3 | vd | 1010111   `vd, vs2, simm5[, ...]`
    case vVUI       // funct6 | vm | vs2 | uimm5 | funct3 | vd | 1010111   `vd, vs2, uimm5[, v0.t]`
    case vVUI6      // funct5 | imm[5] | vm | vs2 | imm[4:0] | 011 | vd | 1010111   `vd, vs2, uimm6[, v0.t]` (vror.vi)
    case vMAccVV    // multiply-add: as vVV, printed `vd, vs1, vs2[, v0.t]`
    case vMAccVX    // multiply-add: as vVX, printed `vd, rs1, vs2[, v0.t]`
    case vMAccVF    // multiply-add: as vVF, printed `vd, fs1, vs2[, v0.t]`
    case vUnary     // funct6 | vm | vs2 | fixed_vs1 | funct3 | vd | 1010111   `vd, vs2[, v0.t]` (vzext, vfcvt, vmv<n>r.v, ...)
    case vNullary   // funct6 | vm | 00000 | fixed_vs1 | 010 | vd | 1010111    `vd[, v0.t]` (vid.v)
    case vToX       // funct6 | vm | vs2 | fixed_vs1 | 010 | rd | 1010111      `rd, vs2[, v0.t]` (vmv.x.s, vcpop.m, vfirst.m)
    case vToF       // funct6 | 1 | vs2 | 00000 | 001 | fd | 1010111           `fd, vs2` (vfmv.f.s)
    case vMvVV      // 010111 | 1 | 00000 | vs1 | 000 | vd | 1010111           `vd, vs1`
    case vMvVX      // funct6 | 1 | 00000 | rs1 | 100/110 | vd | 1010111       `vd, rs1` (vmv.v.x, vmv.s.x)
    case vMvVI      // 010111 | 1 | 00000 | simm5 | 011 | vd | 1010111         `vd, simm5`
    case vMvVF      // funct6 | 1 | 00000 | fs1 | 101 | vd | 1010111           `vd, fs1` (vfmv.v.f, vfmv.s.f)

    // 16-bit compressed (RVC & Zcb) formats
    case cFixed     // c.ebreak, c.unimp, c.mop.N, c.ntl.*
    case cNop       // c.nop [imm6]: rd = x0 (a nonzero immediate is a HINT)
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

/// Per-descriptor operand rules beyond the bit layout.
///
/// The `vd*` and `group*` rules are the RVV 1.0 register-overlap and register-group alignment constraints
/// that LLVM MC enforces at assembly time (an instruction violating one is rejected, not encoded):
/// `RV64Encoder.validate(_:)` reports them, and the exhaustive oracle test checks that LLVM rejects
/// exactly the operand combinations `validate` rejects.
@frozen
public struct RV64DescFlags: OptionSet, Sendable, BitwiseCopyable, Hashable {
    public let rawValue: UInt8

    @inlinable
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// The rounding mode defaults to `rne` rather than `dyn` (LLVM `frmarglegacy`: exact widening
    /// conversions such as `fcvt.d.w`), so the disassembler omits `rne` and prints `dyn` explicitly.
    public static let rmDefaultRNE = RV64DescFlags(rawValue: 1 << 0)
    /// `vd` may not be `v0` when the instruction is masked (`v0.t`) or takes `v0` as carry-in/merge mask.
    public static let vdNotMask    = RV64DescFlags(rawValue: 1 << 1)
    /// `vd` may not equal `vs2` (widening, gathers, slide-ups, `viota.m`, `vmsbf.m`, `vcompress.vm`, ...).
    public static let vdNotVs2     = RV64DescFlags(rawValue: 1 << 2)
    /// `vd` may not equal `vs1` (widening `.vv`/`.wv`, `vrgather.vv`, `vcompress.vm`).
    public static let vdNotVs1     = RV64DescFlags(rawValue: 1 << 3)
    /// Vector register operands name a group of 2, 4, or 8 registers and must be aligned to it
    /// (`vl2re8.v`, `vs4r.v`, `vmv8r.v`, ...).
    public static let group2       = RV64DescFlags(rawValue: 1 << 4)
    public static let group4       = RV64DescFlags(rawValue: 1 << 5)
    public static let group8       = RV64DescFlags(rawValue: 1 << 6)

    /// Register-group size (1, 2, 4, or 8) implied by the `group*` flags.
    @inlinable
    public var registerGroup: UInt8 {
        if contains(.group8) { return 8 }
        if contains(.group4) { return 4 }
        if contains(.group2) { return 2 }
        return 1
    }
}

/// Complete enumeration of RV64 (RVA23) instruction opcodes in `RV64InstructionTable`.
@frozen
public enum RV64Opcode: UInt16, CaseIterable, Sendable, BitwiseCopyable, Hashable {
    // RV64I Base (53)
    case lui, auipc, jal, jalr, beq, bne, blt, bge, bltu, bgeu, lb, lh, lw, ld, lbu, lhu, lwu, sb, sh, sw, sd, addi
    case slti, sltiu, xori, ori, andi, slli, srli, srai, add, sub, sll, slt, sltu, xor, srl, sra, or, and, addiw
    case slliw, srliw, sraiw, addw, subw, sllw, srlw, sraw, fence, fence_i, ecall, ebreak

    // Privileged & Zicsr (10)
    case csrrw, csrrs, csrrc, csrrwi, csrrsi, csrrci, sret, mret, wfi, sfence_vma

    // M Extension (13)
    case mul, mulh, mulhsu, mulhu, div, divu, rem, remu, mulw, divw, divuw, remw, remuw

    // A Extension (22)
    case lr_w, sc_w, lr_d, sc_d, amoswap_w, amoadd_w, amoxor_w, amoand_w, amoor_w, amomin_w, amomax_w, amominu_w
    case amomaxu_w, amoswap_d, amoadd_d, amoxor_d, amoand_d, amoor_d, amomin_d, amomax_d, amominu_d, amomaxu_d

    // F, D, Zfa, Zfhmin Extensions (62)
    case flw, fsw, fld, fsd, flh, fsh, fadd_s, fsub_s, fmul_s, fdiv_s, fsqrt_s, fadd_d, fsub_d, fmul_d, fdiv_d
    case fsqrt_d, fsgnj_s, fsgnjn_s, fsgnjx_s, fsgnj_d, fsgnjn_d, fsgnjx_d, fmin_s, fmax_s, fmin_d, fmax_d, feq_s
    case flt_s, fle_s, feq_d, flt_d, fle_d, fcvt_w_s, fcvt_wu_s, fcvt_l_s, fcvt_lu_s, fcvt_s_w, fcvt_s_wu, fcvt_s_l
    case fcvt_s_lu, fcvt_w_d, fcvt_wu_d, fcvt_l_d, fcvt_lu_d, fcvt_d_w, fcvt_d_wu, fcvt_d_l, fcvt_d_lu, fcvt_s_d
    case fcvt_d_s, fmv_x_w, fmv_w_x, fmv_x_d, fmv_d_x, fclass_s, fclass_d, fli_s, fli_d, fminm_s, fmaxm_s, fminm_d
    case fmaxm_d

    // Zba (Address Generation) (8)
    case add_uw, sh1add, sh1add_uw, sh2add, sh2add_uw, sh3add, sh3add_uw, slli_uw

    // Zbb (Basic Bit Manipulation) (24)
    case andn, orn, xnor, clz, clzw, ctz, ctzw, cpop, cpopw, max, maxu, min, minu, sext_b, sext_h, zext_h, rol, rolw
    case ror, rori, roriw, rorw, orc_b, rev8

    // Zbs (Single-Bit Manipulation) (8)
    case bclr, bclri, bext, bexti, binv, binvi, bset, bseti

    // Zicond (Conditional Zero) (2)
    case czero_eqz, czero_nez

    // RVC (16-bit Compressed) & Zcb (50)
    case c_unimp, c_nop, c_addi, c_addiw, c_addi16sp, c_addi4spn, c_li, c_lui, c_srli, c_srai, c_andi, c_sub, c_xor
    case c_or, c_and, c_subw, c_addw, c_slli, c_mv, c_add, c_lw, c_ld, c_sw, c_sd, c_lwsp, c_ldsp, c_swsp, c_sdsp
    case c_fld, c_fsd, c_fldsp, c_fsdsp, c_j, c_jr, c_jalr, c_beqz, c_bnez, c_ebreak, c_zext_b, c_sext_b, c_zext_h
    case c_sext_h, c_zext_w, c_not, c_mul, c_lbu, c_lhu, c_lh, c_sb, c_sh

    // RVV 1.0 configuration (3)
    case vsetvli, vsetivli, vsetvl

    // Base & Zifencei additions (1)
    case fence_tso

    // F & D fused multiply-add (8)
    case fmadd_s, fmadd_d, fmsub_s, fmsub_d, fnmsub_s, fnmsub_d, fnmadd_s, fnmadd_d

    // Zfa (remaining) (9)
    case fround_s, froundnx_s, fround_d, froundnx_d, fcvtmod_w_d, fleq_s, fltq_s, fleq_d, fltq_d

    // Zfhmin (6)
    case fmv_x_h, fmv_h_x, fcvt_s_h, fcvt_h_s, fcvt_d_h, fcvt_h_d

    // Zicbom, Zicboz & Zicbop (7)
    case cbo_inval, cbo_clean, cbo_flush, cbo_zero, prefetch_i, prefetch_r, prefetch_w

    // Zihintpause, Zihintntl & Zawrs (7)
    case pause, ntl_p1, ntl_pall, ntl_s1, ntl_all, wrs_nto, wrs_sto

    // Zimop (40)
    case mop_r_0, mop_r_1, mop_r_2, mop_r_3, mop_r_4, mop_r_5, mop_r_6, mop_r_7, mop_r_8, mop_r_9, mop_r_10, mop_r_11
    case mop_r_12, mop_r_13, mop_r_14, mop_r_15, mop_r_16, mop_r_17, mop_r_18, mop_r_19, mop_r_20, mop_r_21, mop_r_22
    case mop_r_23, mop_r_24, mop_r_25, mop_r_26, mop_r_27, mop_r_28, mop_r_29, mop_r_30, mop_r_31, mop_rr_0, mop_rr_1
    case mop_rr_2, mop_rr_3, mop_rr_4, mop_rr_5, mop_rr_6, mop_rr_7

    // Svinval & H (hypervisor) (20)
    case sinval_vma, sfence_w_inval, sfence_inval_ir, hfence_vvma, hfence_gvma, hinval_vvma, hinval_gvma, hlv_b
    case hlv_bu, hlv_h, hlv_hu, hlvx_hu, hlv_w, hlv_wu, hlvx_wu, hlv_d, hsv_b, hsv_h, hsv_w, hsv_d

    // Zcmop & Zihintntl (compressed) (12)
    case c_mop_1, c_mop_3, c_mop_5, c_mop_7, c_mop_9, c_mop_11, c_mop_13, c_mop_15, c_ntl_p1, c_ntl_pall, c_ntl_s1
    case c_ntl_all

    // RVV integer arithmetic (OPIVV/OPIVX/OPIVI) (118)
    case vadd_vv, vadd_vx, vadd_vi, vsub_vv, vsub_vx, vrsub_vx, vrsub_vi, vminu_vv, vminu_vx, vmin_vv, vmin_vx
    case vmaxu_vv, vmaxu_vx, vmax_vv, vmax_vx, vand_vv, vand_vx, vand_vi, vor_vv, vor_vx, vor_vi, vxor_vv, vxor_vx
    case vxor_vi, vrgather_vv, vrgather_vx, vrgather_vi, vrgatherei16_vv, vslideup_vx, vslideup_vi, vslidedown_vx
    case vslidedown_vi, vadc_vvm, vadc_vxm, vadc_vim, vmadc_vvm, vmadc_vxm, vmadc_vim, vmadc_vv, vmadc_vx, vmadc_vi
    case vsbc_vvm, vsbc_vxm, vmsbc_vvm, vmsbc_vxm, vmsbc_vv, vmsbc_vx, vmerge_vvm, vmerge_vxm, vmerge_vim, vmv_v_v
    case vmv_v_x, vmv_v_i, vmseq_vv, vmseq_vx, vmseq_vi, vmsne_vv, vmsne_vx, vmsne_vi, vmsltu_vv, vmsltu_vx, vmslt_vv
    case vmslt_vx, vmsleu_vv, vmsleu_vx, vmsleu_vi, vmsle_vv, vmsle_vx, vmsle_vi, vmsgtu_vx, vmsgtu_vi, vmsgt_vx
    case vmsgt_vi, vsaddu_vv, vsaddu_vx, vsaddu_vi, vsadd_vv, vsadd_vx, vsadd_vi, vssubu_vv, vssubu_vx, vssub_vv
    case vssub_vx, vsll_vv, vsll_vx, vsll_vi, vsmul_vv, vsmul_vx, vmv1r_v, vmv2r_v, vmv4r_v, vmv8r_v, vsrl_vv, vsrl_vx
    case vsrl_vi, vsra_vv, vsra_vx, vsra_vi, vssrl_vv, vssrl_vx, vssrl_vi, vssra_vv, vssra_vx, vssra_vi, vnsrl_wv
    case vnsrl_wx, vnsrl_wi, vnsra_wv, vnsra_wx, vnsra_wi, vnclipu_wv, vnclipu_wx, vnclipu_wi, vnclip_wv, vnclip_wx
    case vnclip_wi, vwredsumu_vs, vwredsum_vs

    // RVV integer multiply, divide, reductions & mask ops (OPMVV/OPMVX) (95)
    case vredsum_vs, vredand_vs, vredor_vs, vredxor_vs, vredminu_vs, vredmin_vs, vredmaxu_vs, vredmax_vs, vaaddu_vv
    case vaaddu_vx, vaadd_vv, vaadd_vx, vasubu_vv, vasubu_vx, vasub_vv, vasub_vx, vslide1up_vx, vslide1down_vx
    case vmv_x_s, vcpop_m, vfirst_m, vmv_s_x, vzext_vf8, vsext_vf8, vzext_vf4, vsext_vf4, vzext_vf2, vsext_vf2
    case vmsbf_m, vmsof_m, vmsif_m, viota_m, vid_v, vcompress_vm, vmandn_mm, vmand_mm, vmor_mm, vmxor_mm, vmorn_mm
    case vmnand_mm, vmnor_mm, vmxnor_mm, vdivu_vv, vdivu_vx, vdiv_vv, vdiv_vx, vremu_vv, vremu_vx, vrem_vv, vrem_vx
    case vmulhu_vv, vmulhu_vx, vmul_vv, vmul_vx, vmulhsu_vv, vmulhsu_vx, vmulh_vv, vmulh_vx, vmadd_vv, vmadd_vx
    case vnmsub_vv, vnmsub_vx, vmacc_vv, vmacc_vx, vnmsac_vv, vnmsac_vx, vwaddu_vv, vwaddu_vx, vwadd_vv, vwadd_vx
    case vwsubu_vv, vwsubu_vx, vwsub_vv, vwsub_vx, vwaddu_wv, vwaddu_wx, vwadd_wv, vwadd_wx, vwsubu_wv, vwsubu_wx
    case vwsub_wv, vwsub_wx, vwmulu_vv, vwmulu_vx, vwmulsu_vv, vwmulsu_vx, vwmul_vv, vwmul_vx, vwmaccu_vv, vwmaccu_vx
    case vwmacc_vv, vwmacc_vx, vwmaccus_vx, vwmaccsu_vv, vwmaccsu_vx

    // RVV floating-point (OPFVV/OPFVF) (101)
    case vfadd_vv, vfadd_vf, vfredusum_vs, vfsub_vv, vfsub_vf, vfredosum_vs, vfmin_vv, vfmin_vf, vfredmin_vs, vfmax_vv
    case vfmax_vf, vfredmax_vs, vfsgnj_vv, vfsgnj_vf, vfsgnjn_vv, vfsgnjn_vf, vfsgnjx_vv, vfsgnjx_vf, vfslide1up_vf
    case vfslide1down_vf, vfmv_f_s, vfmv_s_f, vfcvt_xu_f_v, vfcvt_x_f_v, vfcvt_f_xu_v, vfcvt_f_x_v, vfcvt_rtz_xu_f_v
    case vfcvt_rtz_x_f_v, vfwcvt_xu_f_v, vfwcvt_x_f_v, vfwcvt_f_xu_v, vfwcvt_f_x_v, vfwcvt_f_f_v, vfwcvt_rtz_xu_f_v
    case vfwcvt_rtz_x_f_v, vfncvt_xu_f_w, vfncvt_x_f_w, vfncvt_f_xu_w, vfncvt_f_x_w, vfncvt_f_f_w, vfncvt_rod_f_f_w
    case vfncvt_rtz_xu_f_w, vfncvt_rtz_x_f_w, vfsqrt_v, vfrsqrt7_v, vfrec7_v, vfclass_v, vfmerge_vfm, vfmv_v_f
    case vmfeq_vv, vmfeq_vf, vmfle_vv, vmfle_vf, vmflt_vv, vmflt_vf, vmfne_vv, vmfne_vf, vmfgt_vf, vmfge_vf, vfdiv_vv
    case vfdiv_vf, vfrdiv_vf, vfmul_vv, vfmul_vf, vfrsub_vf, vfmadd_vv, vfmadd_vf, vfnmadd_vv, vfnmadd_vf, vfmsub_vv
    case vfmsub_vf, vfnmsub_vv, vfnmsub_vf, vfmacc_vv, vfmacc_vf, vfnmacc_vv, vfnmacc_vf, vfmsac_vv, vfmsac_vf
    case vfnmsac_vv, vfnmsac_vf, vfwadd_vv, vfwadd_vf, vfwredusum_vs, vfwsub_vv, vfwsub_vf, vfwredosum_vs, vfwadd_wv
    case vfwadd_wf, vfwsub_wv, vfwsub_wf, vfwmul_vv, vfwmul_vf, vfwmacc_vv, vfwmacc_vf, vfwnmacc_vv, vfwnmacc_vf
    case vfwmsac_vv, vfwmsac_vf, vfwnmsac_vv, vfwnmsac_vf

    // Zvbb & Zvkb (vector basic bit-manipulation) (16)
    case vandn_vv, vandn_vx, vbrev8_v, vrev8_v, vbrev_v, vclz_v, vctz_v, vcpop_v, vrol_vv, vrol_vx, vror_vv, vror_vx
    case vror_vi, vwsll_vv, vwsll_vx, vwsll_vi

    // RVV loads & stores (58)
    case vle8_v, vse8_v, vle8ff_v, vlse8_v, vsse8_v, vluxei8_v, vloxei8_v, vsuxei8_v, vsoxei8_v, vle16_v, vse16_v
    case vle16ff_v, vlse16_v, vsse16_v, vluxei16_v, vloxei16_v, vsuxei16_v, vsoxei16_v, vle32_v, vse32_v, vle32ff_v
    case vlse32_v, vsse32_v, vluxei32_v, vloxei32_v, vsuxei32_v, vsoxei32_v, vle64_v, vse64_v, vle64ff_v, vlse64_v
    case vsse64_v, vluxei64_v, vloxei64_v, vsuxei64_v, vsoxei64_v, vlm_v, vsm_v, vl1re8_v, vl1re16_v, vl1re32_v
    case vl1re64_v, vs1r_v, vl2re8_v, vl2re16_v, vl2re32_v, vl2re64_v, vs2r_v, vl4re8_v, vl4re16_v, vl4re32_v
    case vl4re64_v, vs4r_v, vl8re8_v, vl8re16_v, vl8re32_v, vl8re64_v, vs8r_v

    // RVV segment loads & stores (252)
    case vlseg2e8_v, vsseg2e8_v, vlseg2e8ff_v, vlsseg2e8_v, vssseg2e8_v, vluxseg2ei8_v, vloxseg2ei8_v, vsuxseg2ei8_v
    case vsoxseg2ei8_v, vlseg2e16_v, vsseg2e16_v, vlseg2e16ff_v, vlsseg2e16_v, vssseg2e16_v, vluxseg2ei16_v
    case vloxseg2ei16_v, vsuxseg2ei16_v, vsoxseg2ei16_v, vlseg2e32_v, vsseg2e32_v, vlseg2e32ff_v, vlsseg2e32_v
    case vssseg2e32_v, vluxseg2ei32_v, vloxseg2ei32_v, vsuxseg2ei32_v, vsoxseg2ei32_v, vlseg2e64_v, vsseg2e64_v
    case vlseg2e64ff_v, vlsseg2e64_v, vssseg2e64_v, vluxseg2ei64_v, vloxseg2ei64_v, vsuxseg2ei64_v, vsoxseg2ei64_v
    case vlseg3e8_v, vsseg3e8_v, vlseg3e8ff_v, vlsseg3e8_v, vssseg3e8_v, vluxseg3ei8_v, vloxseg3ei8_v, vsuxseg3ei8_v
    case vsoxseg3ei8_v, vlseg3e16_v, vsseg3e16_v, vlseg3e16ff_v, vlsseg3e16_v, vssseg3e16_v, vluxseg3ei16_v
    case vloxseg3ei16_v, vsuxseg3ei16_v, vsoxseg3ei16_v, vlseg3e32_v, vsseg3e32_v, vlseg3e32ff_v, vlsseg3e32_v
    case vssseg3e32_v, vluxseg3ei32_v, vloxseg3ei32_v, vsuxseg3ei32_v, vsoxseg3ei32_v, vlseg3e64_v, vsseg3e64_v
    case vlseg3e64ff_v, vlsseg3e64_v, vssseg3e64_v, vluxseg3ei64_v, vloxseg3ei64_v, vsuxseg3ei64_v, vsoxseg3ei64_v
    case vlseg4e8_v, vsseg4e8_v, vlseg4e8ff_v, vlsseg4e8_v, vssseg4e8_v, vluxseg4ei8_v, vloxseg4ei8_v, vsuxseg4ei8_v
    case vsoxseg4ei8_v, vlseg4e16_v, vsseg4e16_v, vlseg4e16ff_v, vlsseg4e16_v, vssseg4e16_v, vluxseg4ei16_v
    case vloxseg4ei16_v, vsuxseg4ei16_v, vsoxseg4ei16_v, vlseg4e32_v, vsseg4e32_v, vlseg4e32ff_v, vlsseg4e32_v
    case vssseg4e32_v, vluxseg4ei32_v, vloxseg4ei32_v, vsuxseg4ei32_v, vsoxseg4ei32_v, vlseg4e64_v, vsseg4e64_v
    case vlseg4e64ff_v, vlsseg4e64_v, vssseg4e64_v, vluxseg4ei64_v, vloxseg4ei64_v, vsuxseg4ei64_v, vsoxseg4ei64_v
    case vlseg5e8_v, vsseg5e8_v, vlseg5e8ff_v, vlsseg5e8_v, vssseg5e8_v, vluxseg5ei8_v, vloxseg5ei8_v, vsuxseg5ei8_v
    case vsoxseg5ei8_v, vlseg5e16_v, vsseg5e16_v, vlseg5e16ff_v, vlsseg5e16_v, vssseg5e16_v, vluxseg5ei16_v
    case vloxseg5ei16_v, vsuxseg5ei16_v, vsoxseg5ei16_v, vlseg5e32_v, vsseg5e32_v, vlseg5e32ff_v, vlsseg5e32_v
    case vssseg5e32_v, vluxseg5ei32_v, vloxseg5ei32_v, vsuxseg5ei32_v, vsoxseg5ei32_v, vlseg5e64_v, vsseg5e64_v
    case vlseg5e64ff_v, vlsseg5e64_v, vssseg5e64_v, vluxseg5ei64_v, vloxseg5ei64_v, vsuxseg5ei64_v, vsoxseg5ei64_v
    case vlseg6e8_v, vsseg6e8_v, vlseg6e8ff_v, vlsseg6e8_v, vssseg6e8_v, vluxseg6ei8_v, vloxseg6ei8_v, vsuxseg6ei8_v
    case vsoxseg6ei8_v, vlseg6e16_v, vsseg6e16_v, vlseg6e16ff_v, vlsseg6e16_v, vssseg6e16_v, vluxseg6ei16_v
    case vloxseg6ei16_v, vsuxseg6ei16_v, vsoxseg6ei16_v, vlseg6e32_v, vsseg6e32_v, vlseg6e32ff_v, vlsseg6e32_v
    case vssseg6e32_v, vluxseg6ei32_v, vloxseg6ei32_v, vsuxseg6ei32_v, vsoxseg6ei32_v, vlseg6e64_v, vsseg6e64_v
    case vlseg6e64ff_v, vlsseg6e64_v, vssseg6e64_v, vluxseg6ei64_v, vloxseg6ei64_v, vsuxseg6ei64_v, vsoxseg6ei64_v
    case vlseg7e8_v, vsseg7e8_v, vlseg7e8ff_v, vlsseg7e8_v, vssseg7e8_v, vluxseg7ei8_v, vloxseg7ei8_v, vsuxseg7ei8_v
    case vsoxseg7ei8_v, vlseg7e16_v, vsseg7e16_v, vlseg7e16ff_v, vlsseg7e16_v, vssseg7e16_v, vluxseg7ei16_v
    case vloxseg7ei16_v, vsuxseg7ei16_v, vsoxseg7ei16_v, vlseg7e32_v, vsseg7e32_v, vlseg7e32ff_v, vlsseg7e32_v
    case vssseg7e32_v, vluxseg7ei32_v, vloxseg7ei32_v, vsuxseg7ei32_v, vsoxseg7ei32_v, vlseg7e64_v, vsseg7e64_v
    case vlseg7e64ff_v, vlsseg7e64_v, vssseg7e64_v, vluxseg7ei64_v, vloxseg7ei64_v, vsuxseg7ei64_v, vsoxseg7ei64_v
    case vlseg8e8_v, vsseg8e8_v, vlseg8e8ff_v, vlsseg8e8_v, vssseg8e8_v, vluxseg8ei8_v, vloxseg8ei8_v, vsuxseg8ei8_v
    case vsoxseg8ei8_v, vlseg8e16_v, vsseg8e16_v, vlseg8e16ff_v, vlsseg8e16_v, vssseg8e16_v, vluxseg8ei16_v
    case vloxseg8ei16_v, vsuxseg8ei16_v, vsoxseg8ei16_v, vlseg8e32_v, vsseg8e32_v, vlseg8e32ff_v, vlsseg8e32_v
    case vssseg8e32_v, vluxseg8ei32_v, vloxseg8ei32_v, vsuxseg8ei32_v, vsoxseg8ei32_v, vlseg8e64_v, vsseg8e64_v
    case vlseg8e64ff_v, vlsseg8e64_v, vssseg8e64_v, vluxseg8ei64_v, vloxseg8ei64_v, vsuxseg8ei64_v, vsoxseg8ei64_v
}

/// Decoded or constructed RV64 instruction value.
/// Flat, value-type representation (`BitwiseCopyable`, `Sendable`) shared across Codegen, Asm, and Disassembler.
@frozen
public struct RV64Instruction: Sendable, BitwiseCopyable, Hashable, CustomStringConvertible {
    public var opcode: RV64Opcode
    public var rd: UInt8        // GPR, FPR, or VReg index (0..31)
    public var rs1: UInt8       // GPR, FPR, or VReg index (0..31)
    public var rs2: UInt8       // GPR, FPR, or VReg index (0..31)
    public var rs3: UInt8       // FPR index (0..31) of the R4-type (`fmadd.s`, ...) third source
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
        rs3: UInt8 = 0,
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
        self.rs3 = rs3
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
    public let flags: RV64DescFlags

    public init(
        opcode: RV64Opcode,
        mnemonic: String,
        format: RV64EncodingFormat,
        match: UInt32,
        mask: UInt32,
        isCompressed: Bool = false,
        flags: RV64DescFlags = []
    ) {
        self.opcode = opcode
        self.mnemonic = mnemonic
        self.format = format
        self.match = match
        self.mask = mask
        self.isCompressed = isCompressed
        self.flags = flags
    }

    /// True if the `vm` bit is a free operand (the instruction has a `v0.t`-masked form).
    @inlinable
    public var isMaskable: Bool {
        (mask & (1 << 25)) == 0
    }

    /// True if `vm` is fixed to 0: the instruction always reads `v0` as carry-in or merge mask (`vadc.vvm`, `vmerge.vim`).
    @inlinable
    public var readsV0Implicitly: Bool {
        (mask & (1 << 25)) != 0 && (match & (1 << 25)) == 0
    }
}

// MARK: - 3. Shared Instruction Descriptor Table (`RV64InstructionTable`)

public enum RV64InstructionTable {
    /// Master table of all RV64 (RVA23) 32-bit and 16-bit compressed instructions,
    /// indexed directly by `RV64Opcode.rawValue`.
    public static let descriptors: [RV64InstrDesc] = [
        // --- RV64I Base ---
        RV64InstrDesc(opcode: .lui,      mnemonic: "lui",      format: .u,            match: 0x00000037, mask: 0x0000007F),
        RV64InstrDesc(opcode: .auipc,    mnemonic: "auipc",    format: .u,            match: 0x00000017, mask: 0x0000007F),
        RV64InstrDesc(opcode: .jal,      mnemonic: "jal",      format: .j,            match: 0x0000006F, mask: 0x0000007F),
        RV64InstrDesc(opcode: .jalr,     mnemonic: "jalr",     format: .i,            match: 0x00000067, mask: 0x0000707F),
        RV64InstrDesc(opcode: .beq,      mnemonic: "beq",      format: .b,            match: 0x00000063, mask: 0x0000707F),
        RV64InstrDesc(opcode: .bne,      mnemonic: "bne",      format: .b,            match: 0x00001063, mask: 0x0000707F),
        RV64InstrDesc(opcode: .blt,      mnemonic: "blt",      format: .b,            match: 0x00004063, mask: 0x0000707F),
        RV64InstrDesc(opcode: .bge,      mnemonic: "bge",      format: .b,            match: 0x00005063, mask: 0x0000707F),
        RV64InstrDesc(opcode: .bltu,     mnemonic: "bltu",     format: .b,            match: 0x00006063, mask: 0x0000707F),
        RV64InstrDesc(opcode: .bgeu,     mnemonic: "bgeu",     format: .b,            match: 0x00007063, mask: 0x0000707F),
        RV64InstrDesc(opcode: .lb,       mnemonic: "lb",       format: .iLoad,        match: 0x00000003, mask: 0x0000707F),
        RV64InstrDesc(opcode: .lh,       mnemonic: "lh",       format: .iLoad,        match: 0x00001003, mask: 0x0000707F),
        RV64InstrDesc(opcode: .lw,       mnemonic: "lw",       format: .iLoad,        match: 0x00002003, mask: 0x0000707F),
        RV64InstrDesc(opcode: .ld,       mnemonic: "ld",       format: .iLoad,        match: 0x00003003, mask: 0x0000707F),
        RV64InstrDesc(opcode: .lbu,      mnemonic: "lbu",      format: .iLoad,        match: 0x00004003, mask: 0x0000707F),
        RV64InstrDesc(opcode: .lhu,      mnemonic: "lhu",      format: .iLoad,        match: 0x00005003, mask: 0x0000707F),
        RV64InstrDesc(opcode: .lwu,      mnemonic: "lwu",      format: .iLoad,        match: 0x00006003, mask: 0x0000707F),
        RV64InstrDesc(opcode: .sb,       mnemonic: "sb",       format: .s,            match: 0x00000023, mask: 0x0000707F),
        RV64InstrDesc(opcode: .sh,       mnemonic: "sh",       format: .s,            match: 0x00001023, mask: 0x0000707F),
        RV64InstrDesc(opcode: .sw,       mnemonic: "sw",       format: .s,            match: 0x00002023, mask: 0x0000707F),
        RV64InstrDesc(opcode: .sd,       mnemonic: "sd",       format: .s,            match: 0x00003023, mask: 0x0000707F),
        RV64InstrDesc(opcode: .addi,     mnemonic: "addi",     format: .i,            match: 0x00000013, mask: 0x0000707F),
        RV64InstrDesc(opcode: .slti,     mnemonic: "slti",     format: .i,            match: 0x00002013, mask: 0x0000707F),
        RV64InstrDesc(opcode: .sltiu,    mnemonic: "sltiu",    format: .i,            match: 0x00003013, mask: 0x0000707F),
        RV64InstrDesc(opcode: .xori,     mnemonic: "xori",     format: .i,            match: 0x00004013, mask: 0x0000707F),
        RV64InstrDesc(opcode: .ori,      mnemonic: "ori",      format: .i,            match: 0x00006013, mask: 0x0000707F),
        RV64InstrDesc(opcode: .andi,     mnemonic: "andi",     format: .i,            match: 0x00007013, mask: 0x0000707F),
        RV64InstrDesc(opcode: .slli,     mnemonic: "slli",     format: .rShift64,     match: 0x00001013, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .srli,     mnemonic: "srli",     format: .rShift64,     match: 0x00005013, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .srai,     mnemonic: "srai",     format: .rShift64,     match: 0x40005013, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .add,      mnemonic: "add",      format: .r,            match: 0x00000033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .sub,      mnemonic: "sub",      format: .r,            match: 0x40000033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .sll,      mnemonic: "sll",      format: .r,            match: 0x00001033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .slt,      mnemonic: "slt",      format: .r,            match: 0x00002033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .sltu,     mnemonic: "sltu",     format: .r,            match: 0x00003033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .xor,      mnemonic: "xor",      format: .r,            match: 0x00004033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .srl,      mnemonic: "srl",      format: .r,            match: 0x00005033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .sra,      mnemonic: "sra",      format: .r,            match: 0x40005033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .or,       mnemonic: "or",       format: .r,            match: 0x00006033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .and,      mnemonic: "and",      format: .r,            match: 0x00007033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .addiw,    mnemonic: "addiw",    format: .i,            match: 0x0000001B, mask: 0x0000707F),
        RV64InstrDesc(opcode: .slliw,    mnemonic: "slliw",    format: .rShift32,     match: 0x0000101B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .srliw,    mnemonic: "srliw",    format: .rShift32,     match: 0x0000501B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .sraiw,    mnemonic: "sraiw",    format: .rShift32,     match: 0x4000501B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .addw,     mnemonic: "addw",     format: .r,            match: 0x0000003B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .subw,     mnemonic: "subw",     format: .r,            match: 0x4000003B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .sllw,     mnemonic: "sllw",     format: .r,            match: 0x0000103B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .srlw,     mnemonic: "srlw",     format: .r,            match: 0x0000503B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .sraw,     mnemonic: "sraw",     format: .r,            match: 0x4000503B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .fence,    mnemonic: "fence",    format: .fence,        match: 0x0000000F, mask: 0xF00FFFFF),
        RV64InstrDesc(opcode: .fence_i,  mnemonic: "fence.i",  format: .systemFixed,  match: 0x0000100F, mask: 0xFFFFFFFF),
        RV64InstrDesc(opcode: .ecall,    mnemonic: "ecall",    format: .systemFixed,  match: 0x00000073, mask: 0xFFFFFFFF),
        RV64InstrDesc(opcode: .ebreak,   mnemonic: "ebreak",   format: .systemFixed,  match: 0x00100073, mask: 0xFFFFFFFF),

        // --- Privileged & Zicsr ---
        RV64InstrDesc(opcode: .csrrw,       mnemonic: "csrrw",       format: .csrReg,       match: 0x00001073, mask: 0x0000707F),
        RV64InstrDesc(opcode: .csrrs,       mnemonic: "csrrs",       format: .csrReg,       match: 0x00002073, mask: 0x0000707F),
        RV64InstrDesc(opcode: .csrrc,       mnemonic: "csrrc",       format: .csrReg,       match: 0x00003073, mask: 0x0000707F),
        RV64InstrDesc(opcode: .csrrwi,      mnemonic: "csrrwi",      format: .csrImm,       match: 0x00005073, mask: 0x0000707F),
        RV64InstrDesc(opcode: .csrrsi,      mnemonic: "csrrsi",      format: .csrImm,       match: 0x00006073, mask: 0x0000707F),
        RV64InstrDesc(opcode: .csrrci,      mnemonic: "csrrci",      format: .csrImm,       match: 0x00007073, mask: 0x0000707F),
        RV64InstrDesc(opcode: .sret,        mnemonic: "sret",        format: .systemFixed,  match: 0x10200073, mask: 0xFFFFFFFF),
        RV64InstrDesc(opcode: .mret,        mnemonic: "mret",        format: .systemFixed,  match: 0x30200073, mask: 0xFFFFFFFF),
        RV64InstrDesc(opcode: .wfi,         mnemonic: "wfi",         format: .systemFixed,  match: 0x10500073, mask: 0xFFFFFFFF),
        RV64InstrDesc(opcode: .sfence_vma,  mnemonic: "sfence.vma",  format: .sfenceVMA,    match: 0x12000073, mask: 0xFE007FFF),

        // --- M Extension ---
        RV64InstrDesc(opcode: .mul,     mnemonic: "mul",     format: .r,  match: 0x02000033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .mulh,    mnemonic: "mulh",    format: .r,  match: 0x02001033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .mulhsu,  mnemonic: "mulhsu",  format: .r,  match: 0x02002033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .mulhu,   mnemonic: "mulhu",   format: .r,  match: 0x02003033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .div,     mnemonic: "div",     format: .r,  match: 0x02004033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .divu,    mnemonic: "divu",    format: .r,  match: 0x02005033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .rem,     mnemonic: "rem",     format: .r,  match: 0x02006033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .remu,    mnemonic: "remu",    format: .r,  match: 0x02007033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .mulw,    mnemonic: "mulw",    format: .r,  match: 0x0200003B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .divw,    mnemonic: "divw",    format: .r,  match: 0x0200403B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .divuw,   mnemonic: "divuw",   format: .r,  match: 0x0200503B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .remw,    mnemonic: "remw",    format: .r,  match: 0x0200603B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .remuw,   mnemonic: "remuw",   format: .r,  match: 0x0200703B, mask: 0xFE00707F),

        // --- A Extension ---
        RV64InstrDesc(opcode: .lr_w,       mnemonic: "lr.w",       format: .rLR,   match: 0x1000202F, mask: 0xF9F0707F),
        RV64InstrDesc(opcode: .sc_w,       mnemonic: "sc.w",       format: .rAMO,  match: 0x1800202F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .lr_d,       mnemonic: "lr.d",       format: .rLR,   match: 0x1000302F, mask: 0xF9F0707F),
        RV64InstrDesc(opcode: .sc_d,       mnemonic: "sc.d",       format: .rAMO,  match: 0x1800302F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amoswap_w,  mnemonic: "amoswap.w",  format: .rAMO,  match: 0x0800202F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amoadd_w,   mnemonic: "amoadd.w",   format: .rAMO,  match: 0x0000202F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amoxor_w,   mnemonic: "amoxor.w",   format: .rAMO,  match: 0x2000202F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amoand_w,   mnemonic: "amoand.w",   format: .rAMO,  match: 0x6000202F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amoor_w,    mnemonic: "amoor.w",    format: .rAMO,  match: 0x4000202F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amomin_w,   mnemonic: "amomin.w",   format: .rAMO,  match: 0x8000202F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amomax_w,   mnemonic: "amomax.w",   format: .rAMO,  match: 0xA000202F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amominu_w,  mnemonic: "amominu.w",  format: .rAMO,  match: 0xC000202F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amomaxu_w,  mnemonic: "amomaxu.w",  format: .rAMO,  match: 0xE000202F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amoswap_d,  mnemonic: "amoswap.d",  format: .rAMO,  match: 0x0800302F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amoadd_d,   mnemonic: "amoadd.d",   format: .rAMO,  match: 0x0000302F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amoxor_d,   mnemonic: "amoxor.d",   format: .rAMO,  match: 0x2000302F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amoand_d,   mnemonic: "amoand.d",   format: .rAMO,  match: 0x6000302F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amoor_d,    mnemonic: "amoor.d",    format: .rAMO,  match: 0x4000302F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amomin_d,   mnemonic: "amomin.d",   format: .rAMO,  match: 0x8000302F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amomax_d,   mnemonic: "amomax.d",   format: .rAMO,  match: 0xA000302F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amominu_d,  mnemonic: "amominu.d",  format: .rAMO,  match: 0xC000302F, mask: 0xF800707F),
        RV64InstrDesc(opcode: .amomaxu_d,  mnemonic: "amomaxu.d",  format: .rAMO,  match: 0xE000302F, mask: 0xF800707F),

        // --- F, D, Zfa, Zfhmin Extensions ---
        RV64InstrDesc(opcode: .flw,        mnemonic: "flw",        format: .iFPLoad,    match: 0x00002007, mask: 0x0000707F),
        RV64InstrDesc(opcode: .fsw,        mnemonic: "fsw",        format: .sFP,        match: 0x00002027, mask: 0x0000707F),
        RV64InstrDesc(opcode: .fld,        mnemonic: "fld",        format: .iFPLoad,    match: 0x00003007, mask: 0x0000707F),
        RV64InstrDesc(opcode: .fsd,        mnemonic: "fsd",        format: .sFP,        match: 0x00003027, mask: 0x0000707F),
        RV64InstrDesc(opcode: .flh,        mnemonic: "flh",        format: .iFPLoad,    match: 0x00001007, mask: 0x0000707F),
        RV64InstrDesc(opcode: .fsh,        mnemonic: "fsh",        format: .sFP,        match: 0x00001027, mask: 0x0000707F),
        RV64InstrDesc(opcode: .fadd_s,     mnemonic: "fadd.s",     format: .rFP,        match: 0x00000053, mask: 0xFE00007F),
        RV64InstrDesc(opcode: .fsub_s,     mnemonic: "fsub.s",     format: .rFP,        match: 0x08000053, mask: 0xFE00007F),
        RV64InstrDesc(opcode: .fmul_s,     mnemonic: "fmul.s",     format: .rFP,        match: 0x10000053, mask: 0xFE00007F),
        RV64InstrDesc(opcode: .fdiv_s,     mnemonic: "fdiv.s",     format: .rFP,        match: 0x18000053, mask: 0xFE00007F),
        RV64InstrDesc(opcode: .fsqrt_s,    mnemonic: "fsqrt.s",    format: .rFPUnary,   match: 0x58000053, mask: 0xFFF0007F),
        RV64InstrDesc(opcode: .fadd_d,     mnemonic: "fadd.d",     format: .rFP,        match: 0x02000053, mask: 0xFE00007F),
        RV64InstrDesc(opcode: .fsub_d,     mnemonic: "fsub.d",     format: .rFP,        match: 0x0A000053, mask: 0xFE00007F),
        RV64InstrDesc(opcode: .fmul_d,     mnemonic: "fmul.d",     format: .rFP,        match: 0x12000053, mask: 0xFE00007F),
        RV64InstrDesc(opcode: .fdiv_d,     mnemonic: "fdiv.d",     format: .rFP,        match: 0x1A000053, mask: 0xFE00007F),
        RV64InstrDesc(opcode: .fsqrt_d,    mnemonic: "fsqrt.d",    format: .rFPUnary,   match: 0x5A000053, mask: 0xFFF0007F),
        RV64InstrDesc(opcode: .fsgnj_s,    mnemonic: "fsgnj.s",    format: .rFPFixed,   match: 0x20000053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .fsgnjn_s,   mnemonic: "fsgnjn.s",   format: .rFPFixed,   match: 0x20001053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .fsgnjx_s,   mnemonic: "fsgnjx.s",   format: .rFPFixed,   match: 0x20002053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .fsgnj_d,    mnemonic: "fsgnj.d",    format: .rFPFixed,   match: 0x22000053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .fsgnjn_d,   mnemonic: "fsgnjn.d",   format: .rFPFixed,   match: 0x22001053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .fsgnjx_d,   mnemonic: "fsgnjx.d",   format: .rFPFixed,   match: 0x22002053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .fmin_s,     mnemonic: "fmin.s",     format: .rFPFixed,   match: 0x28000053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .fmax_s,     mnemonic: "fmax.s",     format: .rFPFixed,   match: 0x28001053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .fmin_d,     mnemonic: "fmin.d",     format: .rFPFixed,   match: 0x2A000053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .fmax_d,     mnemonic: "fmax.d",     format: .rFPFixed,   match: 0x2A001053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .feq_s,      mnemonic: "feq.s",      format: .rFPCmp,     match: 0xA0002053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .flt_s,      mnemonic: "flt.s",      format: .rFPCmp,     match: 0xA0001053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .fle_s,      mnemonic: "fle.s",      format: .rFPCmp,     match: 0xA0000053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .feq_d,      mnemonic: "feq.d",      format: .rFPCmp,     match: 0xA2002053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .flt_d,      mnemonic: "flt.d",      format: .rFPCmp,     match: 0xA2001053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .fle_d,      mnemonic: "fle.d",      format: .rFPCmp,     match: 0xA2000053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .fcvt_w_s,   mnemonic: "fcvt.w.s",   format: .rFPCvtF2I,  match: 0xC0000053, mask: 0xFFF0007F),
        RV64InstrDesc(opcode: .fcvt_wu_s,  mnemonic: "fcvt.wu.s",  format: .rFPCvtF2I,  match: 0xC0100053, mask: 0xFFF0007F),
        RV64InstrDesc(opcode: .fcvt_l_s,   mnemonic: "fcvt.l.s",   format: .rFPCvtF2I,  match: 0xC0200053, mask: 0xFFF0007F),
        RV64InstrDesc(opcode: .fcvt_lu_s,  mnemonic: "fcvt.lu.s",  format: .rFPCvtF2I,  match: 0xC0300053, mask: 0xFFF0007F),
        RV64InstrDesc(opcode: .fcvt_s_w,   mnemonic: "fcvt.s.w",   format: .rFPCvtI2F,  match: 0xD0000053, mask: 0xFFF0007F),
        RV64InstrDesc(opcode: .fcvt_s_wu,  mnemonic: "fcvt.s.wu",  format: .rFPCvtI2F,  match: 0xD0100053, mask: 0xFFF0007F),
        RV64InstrDesc(opcode: .fcvt_s_l,   mnemonic: "fcvt.s.l",   format: .rFPCvtI2F,  match: 0xD0200053, mask: 0xFFF0007F),
        RV64InstrDesc(opcode: .fcvt_s_lu,  mnemonic: "fcvt.s.lu",  format: .rFPCvtI2F,  match: 0xD0300053, mask: 0xFFF0007F),
        RV64InstrDesc(opcode: .fcvt_w_d,   mnemonic: "fcvt.w.d",   format: .rFPCvtF2I,  match: 0xC2000053, mask: 0xFFF0007F),
        RV64InstrDesc(opcode: .fcvt_wu_d,  mnemonic: "fcvt.wu.d",  format: .rFPCvtF2I,  match: 0xC2100053, mask: 0xFFF0007F),
        RV64InstrDesc(opcode: .fcvt_l_d,   mnemonic: "fcvt.l.d",   format: .rFPCvtF2I,  match: 0xC2200053, mask: 0xFFF0007F),
        RV64InstrDesc(opcode: .fcvt_lu_d,  mnemonic: "fcvt.lu.d",  format: .rFPCvtF2I,  match: 0xC2300053, mask: 0xFFF0007F),
        RV64InstrDesc(opcode: .fcvt_d_w,   mnemonic: "fcvt.d.w",   format: .rFPCvtI2F,  match: 0xD2000053, mask: 0xFFF0007F, flags: [.rmDefaultRNE]),
        RV64InstrDesc(opcode: .fcvt_d_wu,  mnemonic: "fcvt.d.wu",  format: .rFPCvtI2F,  match: 0xD2100053, mask: 0xFFF0007F, flags: [.rmDefaultRNE]),
        RV64InstrDesc(opcode: .fcvt_d_l,   mnemonic: "fcvt.d.l",   format: .rFPCvtI2F,  match: 0xD2200053, mask: 0xFFF0007F),
        RV64InstrDesc(opcode: .fcvt_d_lu,  mnemonic: "fcvt.d.lu",  format: .rFPCvtI2F,  match: 0xD2300053, mask: 0xFFF0007F),
        RV64InstrDesc(opcode: .fcvt_s_d,   mnemonic: "fcvt.s.d",   format: .rFPUnary,   match: 0x40100053, mask: 0xFFF0007F),
        RV64InstrDesc(opcode: .fcvt_d_s,   mnemonic: "fcvt.d.s",   format: .rFPUnary,   match: 0x42000053, mask: 0xFFF0007F, flags: [.rmDefaultRNE]),
        RV64InstrDesc(opcode: .fmv_x_w,    mnemonic: "fmv.x.w",    format: .rFPMvF2I,   match: 0xE0000053, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .fmv_w_x,    mnemonic: "fmv.w.x",    format: .rFPMvI2F,   match: 0xF0000053, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .fmv_x_d,    mnemonic: "fmv.x.d",    format: .rFPMvF2I,   match: 0xE2000053, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .fmv_d_x,    mnemonic: "fmv.d.x",    format: .rFPMvI2F,   match: 0xF2000053, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .fclass_s,   mnemonic: "fclass.s",   format: .rFPMvF2I,   match: 0xE0001053, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .fclass_d,   mnemonic: "fclass.d",   format: .rFPMvF2I,   match: 0xE2001053, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .fli_s,      mnemonic: "fli.s",      format: .rFLI,       match: 0xF0100053, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .fli_d,      mnemonic: "fli.d",      format: .rFLI,       match: 0xF2100053, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .fminm_s,    mnemonic: "fminm.s",    format: .rFPFixed,   match: 0x28002053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .fmaxm_s,    mnemonic: "fmaxm.s",    format: .rFPFixed,   match: 0x28003053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .fminm_d,    mnemonic: "fminm.d",    format: .rFPFixed,   match: 0x2A002053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .fmaxm_d,    mnemonic: "fmaxm.d",    format: .rFPFixed,   match: 0x2A003053, mask: 0xFE00707F),

        // --- Zba (Address Generation) ---
        RV64InstrDesc(opcode: .add_uw,     mnemonic: "add.uw",     format: .r,         match: 0x0800003B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .sh1add,     mnemonic: "sh1add",     format: .r,         match: 0x20002033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .sh1add_uw,  mnemonic: "sh1add.uw",  format: .r,         match: 0x2000203B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .sh2add,     mnemonic: "sh2add",     format: .r,         match: 0x20004033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .sh2add_uw,  mnemonic: "sh2add.uw",  format: .r,         match: 0x2000403B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .sh3add,     mnemonic: "sh3add",     format: .r,         match: 0x20006033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .sh3add_uw,  mnemonic: "sh3add.uw",  format: .r,         match: 0x2000603B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .slli_uw,    mnemonic: "slli.uw",    format: .rShift64,  match: 0x0800101B, mask: 0xFC00707F),

        // --- Zbb (Basic Bit Manipulation) ---
        RV64InstrDesc(opcode: .andn,    mnemonic: "andn",    format: .r,         match: 0x40007033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .orn,     mnemonic: "orn",     format: .r,         match: 0x40006033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .xnor,    mnemonic: "xnor",    format: .r,         match: 0x40004033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .clz,     mnemonic: "clz",     format: .rUnary,    match: 0x60001013, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .clzw,    mnemonic: "clzw",    format: .rUnary,    match: 0x6000101B, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .ctz,     mnemonic: "ctz",     format: .rUnary,    match: 0x60101013, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .ctzw,    mnemonic: "ctzw",    format: .rUnary,    match: 0x6010101B, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .cpop,    mnemonic: "cpop",    format: .rUnary,    match: 0x60201013, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .cpopw,   mnemonic: "cpopw",   format: .rUnary,    match: 0x6020101B, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .max,     mnemonic: "max",     format: .r,         match: 0x0A006033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .maxu,    mnemonic: "maxu",    format: .r,         match: 0x0A007033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .min,     mnemonic: "min",     format: .r,         match: 0x0A004033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .minu,    mnemonic: "minu",    format: .r,         match: 0x0A005033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .sext_b,  mnemonic: "sext.b",  format: .rUnary,    match: 0x60401013, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .sext_h,  mnemonic: "sext.h",  format: .rUnary,    match: 0x60501013, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .zext_h,  mnemonic: "zext.h",  format: .rUnary,    match: 0x0800403B, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .rol,     mnemonic: "rol",     format: .r,         match: 0x60001033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .rolw,    mnemonic: "rolw",    format: .r,         match: 0x6000103B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .ror,     mnemonic: "ror",     format: .r,         match: 0x60005033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .rori,    mnemonic: "rori",    format: .rShift64,  match: 0x60005013, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .roriw,   mnemonic: "roriw",   format: .rShift32,  match: 0x6000501B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .rorw,    mnemonic: "rorw",    format: .r,         match: 0x6000503B, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .orc_b,   mnemonic: "orc.b",   format: .rUnary,    match: 0x28705013, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .rev8,    mnemonic: "rev8",    format: .rUnary,    match: 0x6B805013, mask: 0xFFF0707F),

        // --- Zbs (Single-Bit Manipulation) ---
        RV64InstrDesc(opcode: .bclr,   mnemonic: "bclr",   format: .r,         match: 0x48001033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .bclri,  mnemonic: "bclri",  format: .rShift64,  match: 0x48001013, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .bext,   mnemonic: "bext",   format: .r,         match: 0x48005033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .bexti,  mnemonic: "bexti",  format: .rShift64,  match: 0x48005013, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .binv,   mnemonic: "binv",   format: .r,         match: 0x68001033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .binvi,  mnemonic: "binvi",  format: .rShift64,  match: 0x68001013, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .bset,   mnemonic: "bset",   format: .r,         match: 0x28001033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .bseti,  mnemonic: "bseti",  format: .rShift64,  match: 0x28001013, mask: 0xFC00707F),

        // --- Zicond (Conditional Zero) ---
        RV64InstrDesc(opcode: .czero_eqz,  mnemonic: "czero.eqz",  format: .r,  match: 0x0E005033, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .czero_nez,  mnemonic: "czero.nez",  format: .r,  match: 0x0E007033, mask: 0xFE00707F),

        // --- RVC (16-bit Compressed) & Zcb ---
        RV64InstrDesc(opcode: .c_unimp,     mnemonic: "c.unimp",     format: .cFixed,     match: 0x0000, mask: 0xFFFF, isCompressed: true),
        RV64InstrDesc(opcode: .c_nop,       mnemonic: "c.nop",       format: .cNop,       match: 0x0001, mask: 0xEF83, isCompressed: true),
        RV64InstrDesc(opcode: .c_addi,      mnemonic: "c.addi",      format: .cAddi,      match: 0x0001, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_addiw,     mnemonic: "c.addiw",     format: .cAddi,      match: 0x2001, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_addi16sp,  mnemonic: "c.addi16sp",  format: .cAddi16sp,  match: 0x6101, mask: 0xEF83, isCompressed: true),
        RV64InstrDesc(opcode: .c_addi4spn,  mnemonic: "c.addi4spn",  format: .cAddi4spn,  match: 0x0000, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_li,        mnemonic: "c.li",        format: .cAddi,      match: 0x4001, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_lui,       mnemonic: "c.lui",       format: .cLui,       match: 0x6001, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_srli,      mnemonic: "c.srli",      format: .cShift,     match: 0x8001, mask: 0xEC03, isCompressed: true),
        RV64InstrDesc(opcode: .c_srai,      mnemonic: "c.srai",      format: .cShift,     match: 0x8401, mask: 0xEC03, isCompressed: true),
        RV64InstrDesc(opcode: .c_andi,      mnemonic: "c.andi",      format: .cAndi,      match: 0x8801, mask: 0xEC03, isCompressed: true),
        RV64InstrDesc(opcode: .c_sub,       mnemonic: "c.sub",       format: .cAlu,       match: 0x8C01, mask: 0xFC63, isCompressed: true),
        RV64InstrDesc(opcode: .c_xor,       mnemonic: "c.xor",       format: .cAlu,       match: 0x8C21, mask: 0xFC63, isCompressed: true),
        RV64InstrDesc(opcode: .c_or,        mnemonic: "c.or",        format: .cAlu,       match: 0x8C41, mask: 0xFC63, isCompressed: true),
        RV64InstrDesc(opcode: .c_and,       mnemonic: "c.and",       format: .cAlu,       match: 0x8C61, mask: 0xFC63, isCompressed: true),
        RV64InstrDesc(opcode: .c_subw,      mnemonic: "c.subw",      format: .cAlu,       match: 0x9C01, mask: 0xFC63, isCompressed: true),
        RV64InstrDesc(opcode: .c_addw,      mnemonic: "c.addw",      format: .cAlu,       match: 0x9C21, mask: 0xFC63, isCompressed: true),
        RV64InstrDesc(opcode: .c_slli,      mnemonic: "c.slli",      format: .cSlli,      match: 0x0002, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_mv,        mnemonic: "c.mv",        format: .cCR,        match: 0x8002, mask: 0xF003, isCompressed: true),
        RV64InstrDesc(opcode: .c_add,       mnemonic: "c.add",       format: .cCR,        match: 0x9002, mask: 0xF003, isCompressed: true),
        RV64InstrDesc(opcode: .c_lw,        mnemonic: "c.lw",        format: .cLw,        match: 0x4000, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_ld,        mnemonic: "c.ld",        format: .cLd,        match: 0x6000, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_sw,        mnemonic: "c.sw",        format: .cSw,        match: 0xC000, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_sd,        mnemonic: "c.sd",        format: .cSd,        match: 0xE000, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_lwsp,      mnemonic: "c.lwsp",      format: .cLwsp,      match: 0x4002, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_ldsp,      mnemonic: "c.ldsp",      format: .cLdsp,      match: 0x6002, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_swsp,      mnemonic: "c.swsp",      format: .cSwsp,      match: 0xC002, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_sdsp,      mnemonic: "c.sdsp",      format: .cSdsp,      match: 0xE002, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_fld,       mnemonic: "c.fld",       format: .cFld,       match: 0x2000, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_fsd,       mnemonic: "c.fsd",       format: .cFsd,       match: 0xA000, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_fldsp,     mnemonic: "c.fldsp",     format: .cFldsp,     match: 0x2002, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_fsdsp,     mnemonic: "c.fsdsp",     format: .cFsdsp,     match: 0xA002, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_j,         mnemonic: "c.j",         format: .cJ,         match: 0xA001, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_jr,        mnemonic: "c.jr",        format: .cJr,        match: 0x8002, mask: 0xF07F, isCompressed: true),
        RV64InstrDesc(opcode: .c_jalr,      mnemonic: "c.jalr",      format: .cJr,        match: 0x9002, mask: 0xF07F, isCompressed: true),
        RV64InstrDesc(opcode: .c_beqz,      mnemonic: "c.beqz",      format: .cBranch,    match: 0xC001, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_bnez,      mnemonic: "c.bnez",      format: .cBranch,    match: 0xE001, mask: 0xE003, isCompressed: true),
        RV64InstrDesc(opcode: .c_ebreak,    mnemonic: "c.ebreak",    format: .cFixed,     match: 0x9002, mask: 0xFFFF, isCompressed: true),
        RV64InstrDesc(opcode: .c_zext_b,    mnemonic: "c.zext.b",    format: .cZcbUnary,  match: 0x9C61, mask: 0xFC7F, isCompressed: true),
        RV64InstrDesc(opcode: .c_sext_b,    mnemonic: "c.sext.b",    format: .cZcbUnary,  match: 0x9C65, mask: 0xFC7F, isCompressed: true),
        RV64InstrDesc(opcode: .c_zext_h,    mnemonic: "c.zext.h",    format: .cZcbUnary,  match: 0x9C69, mask: 0xFC7F, isCompressed: true),
        RV64InstrDesc(opcode: .c_sext_h,    mnemonic: "c.sext.h",    format: .cZcbUnary,  match: 0x9C6D, mask: 0xFC7F, isCompressed: true),
        RV64InstrDesc(opcode: .c_zext_w,    mnemonic: "c.zext.w",    format: .cZcbUnary,  match: 0x9C71, mask: 0xFC7F, isCompressed: true),
        RV64InstrDesc(opcode: .c_not,       mnemonic: "c.not",       format: .cZcbUnary,  match: 0x9C75, mask: 0xFC7F, isCompressed: true),
        RV64InstrDesc(opcode: .c_mul,       mnemonic: "c.mul",       format: .cAlu,       match: 0x9C41, mask: 0xFC63, isCompressed: true),
        RV64InstrDesc(opcode: .c_lbu,       mnemonic: "c.lbu",       format: .cZcbByte,   match: 0x8000, mask: 0xFC03, isCompressed: true),
        RV64InstrDesc(opcode: .c_lhu,       mnemonic: "c.lhu",       format: .cZcbHalf,   match: 0x8400, mask: 0xFC43, isCompressed: true),
        RV64InstrDesc(opcode: .c_lh,        mnemonic: "c.lh",        format: .cZcbHalf,   match: 0x8440, mask: 0xFC43, isCompressed: true),
        RV64InstrDesc(opcode: .c_sb,        mnemonic: "c.sb",        format: .cZcbByte,   match: 0x8800, mask: 0xFC03, isCompressed: true),
        RV64InstrDesc(opcode: .c_sh,        mnemonic: "c.sh",        format: .cZcbHalf,   match: 0x8C00, mask: 0xFC43, isCompressed: true),

        // --- RVV 1.0 configuration ---
        RV64InstrDesc(opcode: .vsetvli,   mnemonic: "vsetvli",   format: .vsetvli,   match: 0x00007057, mask: 0x8000707F),
        RV64InstrDesc(opcode: .vsetivli,  mnemonic: "vsetivli",  format: .vsetivli,  match: 0xC0007057, mask: 0xC000707F),
        RV64InstrDesc(opcode: .vsetvl,    mnemonic: "vsetvl",    format: .vsetvl,    match: 0x80007057, mask: 0xFE00707F),

        // --- Base & Zifencei additions ---
        RV64InstrDesc(opcode: .fence_tso,  mnemonic: "fence.tso",  format: .systemFixed,  match: 0x8330000F, mask: 0xFFFFFFFF),

        // --- F & D fused multiply-add ---
        RV64InstrDesc(opcode: .fmadd_s,   mnemonic: "fmadd.s",   format: .rFMA,  match: 0x00000043, mask: 0x0600007F),
        RV64InstrDesc(opcode: .fmadd_d,   mnemonic: "fmadd.d",   format: .rFMA,  match: 0x02000043, mask: 0x0600007F),
        RV64InstrDesc(opcode: .fmsub_s,   mnemonic: "fmsub.s",   format: .rFMA,  match: 0x00000047, mask: 0x0600007F),
        RV64InstrDesc(opcode: .fmsub_d,   mnemonic: "fmsub.d",   format: .rFMA,  match: 0x02000047, mask: 0x0600007F),
        RV64InstrDesc(opcode: .fnmsub_s,  mnemonic: "fnmsub.s",  format: .rFMA,  match: 0x0000004B, mask: 0x0600007F),
        RV64InstrDesc(opcode: .fnmsub_d,  mnemonic: "fnmsub.d",  format: .rFMA,  match: 0x0200004B, mask: 0x0600007F),
        RV64InstrDesc(opcode: .fnmadd_s,  mnemonic: "fnmadd.s",  format: .rFMA,  match: 0x0000004F, mask: 0x0600007F),
        RV64InstrDesc(opcode: .fnmadd_d,  mnemonic: "fnmadd.d",  format: .rFMA,  match: 0x0200004F, mask: 0x0600007F),

        // --- Zfa (remaining) ---
        RV64InstrDesc(opcode: .fround_s,     mnemonic: "fround.s",     format: .rFPUnary,   match: 0x40400053, mask: 0xFFF0007F),
        RV64InstrDesc(opcode: .froundnx_s,   mnemonic: "froundnx.s",   format: .rFPUnary,   match: 0x40500053, mask: 0xFFF0007F),
        RV64InstrDesc(opcode: .fround_d,     mnemonic: "fround.d",     format: .rFPUnary,   match: 0x42400053, mask: 0xFFF0007F),
        RV64InstrDesc(opcode: .froundnx_d,   mnemonic: "froundnx.d",   format: .rFPUnary,   match: 0x42500053, mask: 0xFFF0007F),
        RV64InstrDesc(opcode: .fcvtmod_w_d,  mnemonic: "fcvtmod.w.d",  format: .rFPCvtMod,  match: 0xC2801053, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .fleq_s,       mnemonic: "fleq.s",       format: .rFPCmp,     match: 0xA0004053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .fltq_s,       mnemonic: "fltq.s",       format: .rFPCmp,     match: 0xA0005053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .fleq_d,       mnemonic: "fleq.d",       format: .rFPCmp,     match: 0xA2004053, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .fltq_d,       mnemonic: "fltq.d",       format: .rFPCmp,     match: 0xA2005053, mask: 0xFE00707F),

        // --- Zfhmin ---
        RV64InstrDesc(opcode: .fmv_x_h,   mnemonic: "fmv.x.h",   format: .rFPMvF2I,  match: 0xE4000053, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .fmv_h_x,   mnemonic: "fmv.h.x",   format: .rFPMvI2F,  match: 0xF4000053, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .fcvt_s_h,  mnemonic: "fcvt.s.h",  format: .rFPUnary,  match: 0x40200053, mask: 0xFFF0007F, flags: [.rmDefaultRNE]),
        RV64InstrDesc(opcode: .fcvt_h_s,  mnemonic: "fcvt.h.s",  format: .rFPUnary,  match: 0x44000053, mask: 0xFFF0007F),
        RV64InstrDesc(opcode: .fcvt_d_h,  mnemonic: "fcvt.d.h",  format: .rFPUnary,  match: 0x42200053, mask: 0xFFF0007F, flags: [.rmDefaultRNE]),
        RV64InstrDesc(opcode: .fcvt_h_d,  mnemonic: "fcvt.h.d",  format: .rFPUnary,  match: 0x44100053, mask: 0xFFF0007F),

        // --- Zicbom, Zicboz & Zicbop ---
        RV64InstrDesc(opcode: .cbo_inval,   mnemonic: "cbo.inval",   format: .cbo,       match: 0x0000200F, mask: 0xFFF07FFF),
        RV64InstrDesc(opcode: .cbo_clean,   mnemonic: "cbo.clean",   format: .cbo,       match: 0x0010200F, mask: 0xFFF07FFF),
        RV64InstrDesc(opcode: .cbo_flush,   mnemonic: "cbo.flush",   format: .cbo,       match: 0x0020200F, mask: 0xFFF07FFF),
        RV64InstrDesc(opcode: .cbo_zero,    mnemonic: "cbo.zero",    format: .cbo,       match: 0x0040200F, mask: 0xFFF07FFF),
        RV64InstrDesc(opcode: .prefetch_i,  mnemonic: "prefetch.i",  format: .prefetch,  match: 0x00006013, mask: 0x01F07FFF),
        RV64InstrDesc(opcode: .prefetch_r,  mnemonic: "prefetch.r",  format: .prefetch,  match: 0x00106013, mask: 0x01F07FFF),
        RV64InstrDesc(opcode: .prefetch_w,  mnemonic: "prefetch.w",  format: .prefetch,  match: 0x00306013, mask: 0x01F07FFF),

        // --- Zihintpause, Zihintntl & Zawrs ---
        RV64InstrDesc(opcode: .pause,     mnemonic: "pause",     format: .systemFixed,  match: 0x0100000F, mask: 0xFFFFFFFF),
        RV64InstrDesc(opcode: .ntl_p1,    mnemonic: "ntl.p1",    format: .systemFixed,  match: 0x00200033, mask: 0xFFFFFFFF),
        RV64InstrDesc(opcode: .ntl_pall,  mnemonic: "ntl.pall",  format: .systemFixed,  match: 0x00300033, mask: 0xFFFFFFFF),
        RV64InstrDesc(opcode: .ntl_s1,    mnemonic: "ntl.s1",    format: .systemFixed,  match: 0x00400033, mask: 0xFFFFFFFF),
        RV64InstrDesc(opcode: .ntl_all,   mnemonic: "ntl.all",   format: .systemFixed,  match: 0x00500033, mask: 0xFFFFFFFF),
        RV64InstrDesc(opcode: .wrs_nto,   mnemonic: "wrs.nto",   format: .systemFixed,  match: 0x00D00073, mask: 0xFFFFFFFF),
        RV64InstrDesc(opcode: .wrs_sto,   mnemonic: "wrs.sto",   format: .systemFixed,  match: 0x01D00073, mask: 0xFFFFFFFF),

        // --- Zimop ---
        RV64InstrDesc(opcode: .mop_r_0,   mnemonic: "mop.r.0",   format: .rUnary,  match: 0x81C04073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .mop_r_1,   mnemonic: "mop.r.1",   format: .rUnary,  match: 0x81D04073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .mop_r_2,   mnemonic: "mop.r.2",   format: .rUnary,  match: 0x81E04073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .mop_r_3,   mnemonic: "mop.r.3",   format: .rUnary,  match: 0x81F04073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .mop_r_4,   mnemonic: "mop.r.4",   format: .rUnary,  match: 0x85C04073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .mop_r_5,   mnemonic: "mop.r.5",   format: .rUnary,  match: 0x85D04073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .mop_r_6,   mnemonic: "mop.r.6",   format: .rUnary,  match: 0x85E04073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .mop_r_7,   mnemonic: "mop.r.7",   format: .rUnary,  match: 0x85F04073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .mop_r_8,   mnemonic: "mop.r.8",   format: .rUnary,  match: 0x89C04073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .mop_r_9,   mnemonic: "mop.r.9",   format: .rUnary,  match: 0x89D04073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .mop_r_10,  mnemonic: "mop.r.10",  format: .rUnary,  match: 0x89E04073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .mop_r_11,  mnemonic: "mop.r.11",  format: .rUnary,  match: 0x89F04073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .mop_r_12,  mnemonic: "mop.r.12",  format: .rUnary,  match: 0x8DC04073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .mop_r_13,  mnemonic: "mop.r.13",  format: .rUnary,  match: 0x8DD04073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .mop_r_14,  mnemonic: "mop.r.14",  format: .rUnary,  match: 0x8DE04073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .mop_r_15,  mnemonic: "mop.r.15",  format: .rUnary,  match: 0x8DF04073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .mop_r_16,  mnemonic: "mop.r.16",  format: .rUnary,  match: 0xC1C04073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .mop_r_17,  mnemonic: "mop.r.17",  format: .rUnary,  match: 0xC1D04073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .mop_r_18,  mnemonic: "mop.r.18",  format: .rUnary,  match: 0xC1E04073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .mop_r_19,  mnemonic: "mop.r.19",  format: .rUnary,  match: 0xC1F04073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .mop_r_20,  mnemonic: "mop.r.20",  format: .rUnary,  match: 0xC5C04073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .mop_r_21,  mnemonic: "mop.r.21",  format: .rUnary,  match: 0xC5D04073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .mop_r_22,  mnemonic: "mop.r.22",  format: .rUnary,  match: 0xC5E04073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .mop_r_23,  mnemonic: "mop.r.23",  format: .rUnary,  match: 0xC5F04073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .mop_r_24,  mnemonic: "mop.r.24",  format: .rUnary,  match: 0xC9C04073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .mop_r_25,  mnemonic: "mop.r.25",  format: .rUnary,  match: 0xC9D04073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .mop_r_26,  mnemonic: "mop.r.26",  format: .rUnary,  match: 0xC9E04073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .mop_r_27,  mnemonic: "mop.r.27",  format: .rUnary,  match: 0xC9F04073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .mop_r_28,  mnemonic: "mop.r.28",  format: .rUnary,  match: 0xCDC04073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .mop_r_29,  mnemonic: "mop.r.29",  format: .rUnary,  match: 0xCDD04073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .mop_r_30,  mnemonic: "mop.r.30",  format: .rUnary,  match: 0xCDE04073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .mop_r_31,  mnemonic: "mop.r.31",  format: .rUnary,  match: 0xCDF04073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .mop_rr_0,  mnemonic: "mop.rr.0",  format: .r,       match: 0x82004073, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .mop_rr_1,  mnemonic: "mop.rr.1",  format: .r,       match: 0x86004073, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .mop_rr_2,  mnemonic: "mop.rr.2",  format: .r,       match: 0x8A004073, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .mop_rr_3,  mnemonic: "mop.rr.3",  format: .r,       match: 0x8E004073, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .mop_rr_4,  mnemonic: "mop.rr.4",  format: .r,       match: 0xC2004073, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .mop_rr_5,  mnemonic: "mop.rr.5",  format: .r,       match: 0xC6004073, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .mop_rr_6,  mnemonic: "mop.rr.6",  format: .r,       match: 0xCA004073, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .mop_rr_7,  mnemonic: "mop.rr.7",  format: .r,       match: 0xCE004073, mask: 0xFE00707F),

        // --- Svinval & H (hypervisor) ---
        RV64InstrDesc(opcode: .sinval_vma,       mnemonic: "sinval.vma",       format: .sfenceVMA,    match: 0x16000073, mask: 0xFE007FFF),
        RV64InstrDesc(opcode: .sfence_w_inval,   mnemonic: "sfence.w.inval",   format: .systemFixed,  match: 0x18000073, mask: 0xFFFFFFFF),
        RV64InstrDesc(opcode: .sfence_inval_ir,  mnemonic: "sfence.inval.ir",  format: .systemFixed,  match: 0x18100073, mask: 0xFFFFFFFF),
        RV64InstrDesc(opcode: .hfence_vvma,      mnemonic: "hfence.vvma",      format: .sfenceVMA,    match: 0x22000073, mask: 0xFE007FFF),
        RV64InstrDesc(opcode: .hfence_gvma,      mnemonic: "hfence.gvma",      format: .sfenceVMA,    match: 0x62000073, mask: 0xFE007FFF),
        RV64InstrDesc(opcode: .hinval_vvma,      mnemonic: "hinval.vvma",      format: .sfenceVMA,    match: 0x26000073, mask: 0xFE007FFF),
        RV64InstrDesc(opcode: .hinval_gvma,      mnemonic: "hinval.gvma",      format: .sfenceVMA,    match: 0x66000073, mask: 0xFE007FFF),
        RV64InstrDesc(opcode: .hlv_b,            mnemonic: "hlv.b",            format: .hlv,          match: 0x60004073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .hlv_bu,           mnemonic: "hlv.bu",           format: .hlv,          match: 0x60104073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .hlv_h,            mnemonic: "hlv.h",            format: .hlv,          match: 0x64004073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .hlv_hu,           mnemonic: "hlv.hu",           format: .hlv,          match: 0x64104073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .hlvx_hu,          mnemonic: "hlvx.hu",          format: .hlv,          match: 0x64304073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .hlv_w,            mnemonic: "hlv.w",            format: .hlv,          match: 0x68004073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .hlv_wu,           mnemonic: "hlv.wu",           format: .hlv,          match: 0x68104073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .hlvx_wu,          mnemonic: "hlvx.wu",          format: .hlv,          match: 0x68304073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .hlv_d,            mnemonic: "hlv.d",            format: .hlv,          match: 0x6C004073, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .hsv_b,            mnemonic: "hsv.b",            format: .hsv,          match: 0x62004073, mask: 0xFE007FFF),
        RV64InstrDesc(opcode: .hsv_h,            mnemonic: "hsv.h",            format: .hsv,          match: 0x66004073, mask: 0xFE007FFF),
        RV64InstrDesc(opcode: .hsv_w,            mnemonic: "hsv.w",            format: .hsv,          match: 0x6A004073, mask: 0xFE007FFF),
        RV64InstrDesc(opcode: .hsv_d,            mnemonic: "hsv.d",            format: .hsv,          match: 0x6E004073, mask: 0xFE007FFF),

        // --- Zcmop & Zihintntl (compressed) ---
        RV64InstrDesc(opcode: .c_mop_1,     mnemonic: "c.mop.1",     format: .cFixed,  match: 0x6081, mask: 0xFFFF, isCompressed: true),
        RV64InstrDesc(opcode: .c_mop_3,     mnemonic: "c.mop.3",     format: .cFixed,  match: 0x6181, mask: 0xFFFF, isCompressed: true),
        RV64InstrDesc(opcode: .c_mop_5,     mnemonic: "c.mop.5",     format: .cFixed,  match: 0x6281, mask: 0xFFFF, isCompressed: true),
        RV64InstrDesc(opcode: .c_mop_7,     mnemonic: "c.mop.7",     format: .cFixed,  match: 0x6381, mask: 0xFFFF, isCompressed: true),
        RV64InstrDesc(opcode: .c_mop_9,     mnemonic: "c.mop.9",     format: .cFixed,  match: 0x6481, mask: 0xFFFF, isCompressed: true),
        RV64InstrDesc(opcode: .c_mop_11,    mnemonic: "c.mop.11",    format: .cFixed,  match: 0x6581, mask: 0xFFFF, isCompressed: true),
        RV64InstrDesc(opcode: .c_mop_13,    mnemonic: "c.mop.13",    format: .cFixed,  match: 0x6681, mask: 0xFFFF, isCompressed: true),
        RV64InstrDesc(opcode: .c_mop_15,    mnemonic: "c.mop.15",    format: .cFixed,  match: 0x6781, mask: 0xFFFF, isCompressed: true),
        RV64InstrDesc(opcode: .c_ntl_p1,    mnemonic: "c.ntl.p1",    format: .cFixed,  match: 0x900A, mask: 0xFFFF, isCompressed: true),
        RV64InstrDesc(opcode: .c_ntl_pall,  mnemonic: "c.ntl.pall",  format: .cFixed,  match: 0x900E, mask: 0xFFFF, isCompressed: true),
        RV64InstrDesc(opcode: .c_ntl_s1,    mnemonic: "c.ntl.s1",    format: .cFixed,  match: 0x9012, mask: 0xFFFF, isCompressed: true),
        RV64InstrDesc(opcode: .c_ntl_all,   mnemonic: "c.ntl.all",   format: .cFixed,  match: 0x9016, mask: 0xFFFF, isCompressed: true),

        // --- RVV integer arithmetic (OPIVV/OPIVX/OPIVI) ---
        RV64InstrDesc(opcode: .vadd_vv,          mnemonic: "vadd.vv",          format: .vVV,     match: 0x00000057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vadd_vx,          mnemonic: "vadd.vx",          format: .vVX,     match: 0x00004057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vadd_vi,          mnemonic: "vadd.vi",          format: .vVI,     match: 0x00003057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsub_vv,          mnemonic: "vsub.vv",          format: .vVV,     match: 0x08000057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsub_vx,          mnemonic: "vsub.vx",          format: .vVX,     match: 0x08004057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vrsub_vx,         mnemonic: "vrsub.vx",         format: .vVX,     match: 0x0C004057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vrsub_vi,         mnemonic: "vrsub.vi",         format: .vVI,     match: 0x0C003057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vminu_vv,         mnemonic: "vminu.vv",         format: .vVV,     match: 0x10000057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vminu_vx,         mnemonic: "vminu.vx",         format: .vVX,     match: 0x10004057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vmin_vv,          mnemonic: "vmin.vv",          format: .vVV,     match: 0x14000057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vmin_vx,          mnemonic: "vmin.vx",          format: .vVX,     match: 0x14004057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vmaxu_vv,         mnemonic: "vmaxu.vv",         format: .vVV,     match: 0x18000057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vmaxu_vx,         mnemonic: "vmaxu.vx",         format: .vVX,     match: 0x18004057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vmax_vv,          mnemonic: "vmax.vv",          format: .vVV,     match: 0x1C000057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vmax_vx,          mnemonic: "vmax.vx",          format: .vVX,     match: 0x1C004057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vand_vv,          mnemonic: "vand.vv",          format: .vVV,     match: 0x24000057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vand_vx,          mnemonic: "vand.vx",          format: .vVX,     match: 0x24004057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vand_vi,          mnemonic: "vand.vi",          format: .vVI,     match: 0x24003057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vor_vv,           mnemonic: "vor.vv",           format: .vVV,     match: 0x28000057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vor_vx,           mnemonic: "vor.vx",           format: .vVX,     match: 0x28004057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vor_vi,           mnemonic: "vor.vi",           format: .vVI,     match: 0x28003057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vxor_vv,          mnemonic: "vxor.vv",          format: .vVV,     match: 0x2C000057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vxor_vx,          mnemonic: "vxor.vx",          format: .vVX,     match: 0x2C004057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vxor_vi,          mnemonic: "vxor.vi",          format: .vVI,     match: 0x2C003057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vrgather_vv,      mnemonic: "vrgather.vv",      format: .vVV,     match: 0x30000057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vrgather_vx,      mnemonic: "vrgather.vx",      format: .vVX,     match: 0x30004057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotMask]),
        RV64InstrDesc(opcode: .vrgather_vi,      mnemonic: "vrgather.vi",      format: .vVUI,    match: 0x30003057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotMask]),
        RV64InstrDesc(opcode: .vrgatherei16_vv,  mnemonic: "vrgatherei16.vv",  format: .vVV,     match: 0x38000057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vslideup_vx,      mnemonic: "vslideup.vx",      format: .vVX,     match: 0x38004057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotMask]),
        RV64InstrDesc(opcode: .vslideup_vi,      mnemonic: "vslideup.vi",      format: .vVUI,    match: 0x38003057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotMask]),
        RV64InstrDesc(opcode: .vslidedown_vx,    mnemonic: "vslidedown.vx",    format: .vVX,     match: 0x3C004057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vslidedown_vi,    mnemonic: "vslidedown.vi",    format: .vVUI,    match: 0x3C003057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vadc_vvm,         mnemonic: "vadc.vvm",         format: .vVV,     match: 0x40000057, mask: 0xFE00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vadc_vxm,         mnemonic: "vadc.vxm",         format: .vVX,     match: 0x40004057, mask: 0xFE00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vadc_vim,         mnemonic: "vadc.vim",         format: .vVI,     match: 0x40003057, mask: 0xFE00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vmadc_vvm,        mnemonic: "vmadc.vvm",        format: .vVV,     match: 0x44000057, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .vmadc_vxm,        mnemonic: "vmadc.vxm",        format: .vVX,     match: 0x44004057, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .vmadc_vim,        mnemonic: "vmadc.vim",        format: .vVI,     match: 0x44003057, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .vmadc_vv,         mnemonic: "vmadc.vv",         format: .vVV,     match: 0x46000057, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .vmadc_vx,         mnemonic: "vmadc.vx",         format: .vVX,     match: 0x46004057, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .vmadc_vi,         mnemonic: "vmadc.vi",         format: .vVI,     match: 0x46003057, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .vsbc_vvm,         mnemonic: "vsbc.vvm",         format: .vVV,     match: 0x48000057, mask: 0xFE00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsbc_vxm,         mnemonic: "vsbc.vxm",         format: .vVX,     match: 0x48004057, mask: 0xFE00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vmsbc_vvm,        mnemonic: "vmsbc.vvm",        format: .vVV,     match: 0x4C000057, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .vmsbc_vxm,        mnemonic: "vmsbc.vxm",        format: .vVX,     match: 0x4C004057, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .vmsbc_vv,         mnemonic: "vmsbc.vv",         format: .vVV,     match: 0x4E000057, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .vmsbc_vx,         mnemonic: "vmsbc.vx",         format: .vVX,     match: 0x4E004057, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .vmerge_vvm,       mnemonic: "vmerge.vvm",       format: .vVV,     match: 0x5C000057, mask: 0xFE00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vmerge_vxm,       mnemonic: "vmerge.vxm",       format: .vVX,     match: 0x5C004057, mask: 0xFE00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vmerge_vim,       mnemonic: "vmerge.vim",       format: .vVI,     match: 0x5C003057, mask: 0xFE00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vmv_v_v,          mnemonic: "vmv.v.v",          format: .vMvVV,   match: 0x5E000057, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .vmv_v_x,          mnemonic: "vmv.v.x",          format: .vMvVX,   match: 0x5E004057, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .vmv_v_i,          mnemonic: "vmv.v.i",          format: .vMvVI,   match: 0x5E003057, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .vmseq_vv,         mnemonic: "vmseq.vv",         format: .vVV,     match: 0x60000057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vmseq_vx,         mnemonic: "vmseq.vx",         format: .vVX,     match: 0x60004057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vmseq_vi,         mnemonic: "vmseq.vi",         format: .vVI,     match: 0x60003057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vmsne_vv,         mnemonic: "vmsne.vv",         format: .vVV,     match: 0x64000057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vmsne_vx,         mnemonic: "vmsne.vx",         format: .vVX,     match: 0x64004057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vmsne_vi,         mnemonic: "vmsne.vi",         format: .vVI,     match: 0x64003057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vmsltu_vv,        mnemonic: "vmsltu.vv",        format: .vVV,     match: 0x68000057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vmsltu_vx,        mnemonic: "vmsltu.vx",        format: .vVX,     match: 0x68004057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vmslt_vv,         mnemonic: "vmslt.vv",         format: .vVV,     match: 0x6C000057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vmslt_vx,         mnemonic: "vmslt.vx",         format: .vVX,     match: 0x6C004057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vmsleu_vv,        mnemonic: "vmsleu.vv",        format: .vVV,     match: 0x70000057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vmsleu_vx,        mnemonic: "vmsleu.vx",        format: .vVX,     match: 0x70004057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vmsleu_vi,        mnemonic: "vmsleu.vi",        format: .vVI,     match: 0x70003057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vmsle_vv,         mnemonic: "vmsle.vv",         format: .vVV,     match: 0x74000057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vmsle_vx,         mnemonic: "vmsle.vx",         format: .vVX,     match: 0x74004057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vmsle_vi,         mnemonic: "vmsle.vi",         format: .vVI,     match: 0x74003057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vmsgtu_vx,        mnemonic: "vmsgtu.vx",        format: .vVX,     match: 0x78004057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vmsgtu_vi,        mnemonic: "vmsgtu.vi",        format: .vVI,     match: 0x78003057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vmsgt_vx,         mnemonic: "vmsgt.vx",         format: .vVX,     match: 0x7C004057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vmsgt_vi,         mnemonic: "vmsgt.vi",         format: .vVI,     match: 0x7C003057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vsaddu_vv,        mnemonic: "vsaddu.vv",        format: .vVV,     match: 0x80000057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsaddu_vx,        mnemonic: "vsaddu.vx",        format: .vVX,     match: 0x80004057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsaddu_vi,        mnemonic: "vsaddu.vi",        format: .vVI,     match: 0x80003057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsadd_vv,         mnemonic: "vsadd.vv",         format: .vVV,     match: 0x84000057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsadd_vx,         mnemonic: "vsadd.vx",         format: .vVX,     match: 0x84004057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsadd_vi,         mnemonic: "vsadd.vi",         format: .vVI,     match: 0x84003057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssubu_vv,        mnemonic: "vssubu.vv",        format: .vVV,     match: 0x88000057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssubu_vx,        mnemonic: "vssubu.vx",        format: .vVX,     match: 0x88004057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssub_vv,         mnemonic: "vssub.vv",         format: .vVV,     match: 0x8C000057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssub_vx,         mnemonic: "vssub.vx",         format: .vVX,     match: 0x8C004057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsll_vv,          mnemonic: "vsll.vv",          format: .vVV,     match: 0x94000057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsll_vx,          mnemonic: "vsll.vx",          format: .vVX,     match: 0x94004057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsll_vi,          mnemonic: "vsll.vi",          format: .vVUI,    match: 0x94003057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsmul_vv,         mnemonic: "vsmul.vv",         format: .vVV,     match: 0x9C000057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsmul_vx,         mnemonic: "vsmul.vx",         format: .vVX,     match: 0x9C004057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vmv1r_v,          mnemonic: "vmv1r.v",          format: .vUnary,  match: 0x9E003057, mask: 0xFE0FF07F),
        RV64InstrDesc(opcode: .vmv2r_v,          mnemonic: "vmv2r.v",          format: .vUnary,  match: 0x9E00B057, mask: 0xFE0FF07F, flags: [.group2]),
        RV64InstrDesc(opcode: .vmv4r_v,          mnemonic: "vmv4r.v",          format: .vUnary,  match: 0x9E01B057, mask: 0xFE0FF07F, flags: [.group4]),
        RV64InstrDesc(opcode: .vmv8r_v,          mnemonic: "vmv8r.v",          format: .vUnary,  match: 0x9E03B057, mask: 0xFE0FF07F, flags: [.group8]),
        RV64InstrDesc(opcode: .vsrl_vv,          mnemonic: "vsrl.vv",          format: .vVV,     match: 0xA0000057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsrl_vx,          mnemonic: "vsrl.vx",          format: .vVX,     match: 0xA0004057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsrl_vi,          mnemonic: "vsrl.vi",          format: .vVUI,    match: 0xA0003057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsra_vv,          mnemonic: "vsra.vv",          format: .vVV,     match: 0xA4000057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsra_vx,          mnemonic: "vsra.vx",          format: .vVX,     match: 0xA4004057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsra_vi,          mnemonic: "vsra.vi",          format: .vVUI,    match: 0xA4003057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssrl_vv,         mnemonic: "vssrl.vv",         format: .vVV,     match: 0xA8000057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssrl_vx,         mnemonic: "vssrl.vx",         format: .vVX,     match: 0xA8004057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssrl_vi,         mnemonic: "vssrl.vi",         format: .vVUI,    match: 0xA8003057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssra_vv,         mnemonic: "vssra.vv",         format: .vVV,     match: 0xAC000057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssra_vx,         mnemonic: "vssra.vx",         format: .vVX,     match: 0xAC004057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssra_vi,         mnemonic: "vssra.vi",         format: .vVUI,    match: 0xAC003057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vnsrl_wv,         mnemonic: "vnsrl.wv",         format: .vVV,     match: 0xB0000057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vnsrl_wx,         mnemonic: "vnsrl.wx",         format: .vVX,     match: 0xB0004057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vnsrl_wi,         mnemonic: "vnsrl.wi",         format: .vVUI,    match: 0xB0003057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vnsra_wv,         mnemonic: "vnsra.wv",         format: .vVV,     match: 0xB4000057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vnsra_wx,         mnemonic: "vnsra.wx",         format: .vVX,     match: 0xB4004057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vnsra_wi,         mnemonic: "vnsra.wi",         format: .vVUI,    match: 0xB4003057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vnclipu_wv,       mnemonic: "vnclipu.wv",       format: .vVV,     match: 0xB8000057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vnclipu_wx,       mnemonic: "vnclipu.wx",       format: .vVX,     match: 0xB8004057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vnclipu_wi,       mnemonic: "vnclipu.wi",       format: .vVUI,    match: 0xB8003057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vnclip_wv,        mnemonic: "vnclip.wv",        format: .vVV,     match: 0xBC000057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vnclip_wx,        mnemonic: "vnclip.wx",        format: .vVX,     match: 0xBC004057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vnclip_wi,        mnemonic: "vnclip.wi",        format: .vVUI,    match: 0xBC003057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vwredsumu_vs,     mnemonic: "vwredsumu.vs",     format: .vVV,     match: 0xC0000057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vwredsum_vs,      mnemonic: "vwredsum.vs",      format: .vVV,     match: 0xC4000057, mask: 0xFC00707F),

        // --- RVV integer multiply, divide, reductions & mask ops (OPMVV/OPMVX) ---
        RV64InstrDesc(opcode: .vredsum_vs,      mnemonic: "vredsum.vs",      format: .vVV,       match: 0x00002057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vredand_vs,      mnemonic: "vredand.vs",      format: .vVV,       match: 0x04002057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vredor_vs,       mnemonic: "vredor.vs",       format: .vVV,       match: 0x08002057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vredxor_vs,      mnemonic: "vredxor.vs",      format: .vVV,       match: 0x0C002057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vredminu_vs,     mnemonic: "vredminu.vs",     format: .vVV,       match: 0x10002057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vredmin_vs,      mnemonic: "vredmin.vs",      format: .vVV,       match: 0x14002057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vredmaxu_vs,     mnemonic: "vredmaxu.vs",     format: .vVV,       match: 0x18002057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vredmax_vs,      mnemonic: "vredmax.vs",      format: .vVV,       match: 0x1C002057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vaaddu_vv,       mnemonic: "vaaddu.vv",       format: .vVV,       match: 0x20002057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vaaddu_vx,       mnemonic: "vaaddu.vx",       format: .vVX,       match: 0x20006057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vaadd_vv,        mnemonic: "vaadd.vv",        format: .vVV,       match: 0x24002057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vaadd_vx,        mnemonic: "vaadd.vx",        format: .vVX,       match: 0x24006057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vasubu_vv,       mnemonic: "vasubu.vv",       format: .vVV,       match: 0x28002057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vasubu_vx,       mnemonic: "vasubu.vx",       format: .vVX,       match: 0x28006057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vasub_vv,        mnemonic: "vasub.vv",        format: .vVV,       match: 0x2C002057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vasub_vx,        mnemonic: "vasub.vx",        format: .vVX,       match: 0x2C006057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vslide1up_vx,    mnemonic: "vslide1up.vx",    format: .vVX,       match: 0x38006057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotMask]),
        RV64InstrDesc(opcode: .vslide1down_vx,  mnemonic: "vslide1down.vx",  format: .vVX,       match: 0x3C006057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vmv_x_s,         mnemonic: "vmv.x.s",         format: .vToX,      match: 0x42002057, mask: 0xFE0FF07F),
        RV64InstrDesc(opcode: .vcpop_m,         mnemonic: "vcpop.m",         format: .vToX,      match: 0x40082057, mask: 0xFC0FF07F),
        RV64InstrDesc(opcode: .vfirst_m,        mnemonic: "vfirst.m",        format: .vToX,      match: 0x4008A057, mask: 0xFC0FF07F),
        RV64InstrDesc(opcode: .vmv_s_x,         mnemonic: "vmv.s.x",         format: .vMvVX,     match: 0x42006057, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .vzext_vf8,       mnemonic: "vzext.vf8",       format: .vUnary,    match: 0x48012057, mask: 0xFC0FF07F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsext_vf8,       mnemonic: "vsext.vf8",       format: .vUnary,    match: 0x4801A057, mask: 0xFC0FF07F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vzext_vf4,       mnemonic: "vzext.vf4",       format: .vUnary,    match: 0x48022057, mask: 0xFC0FF07F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsext_vf4,       mnemonic: "vsext.vf4",       format: .vUnary,    match: 0x4802A057, mask: 0xFC0FF07F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vzext_vf2,       mnemonic: "vzext.vf2",       format: .vUnary,    match: 0x48032057, mask: 0xFC0FF07F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsext_vf2,       mnemonic: "vsext.vf2",       format: .vUnary,    match: 0x4803A057, mask: 0xFC0FF07F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vmsbf_m,         mnemonic: "vmsbf.m",         format: .vUnary,    match: 0x5000A057, mask: 0xFC0FF07F, flags: [.vdNotVs2, .vdNotMask]),
        RV64InstrDesc(opcode: .vmsof_m,         mnemonic: "vmsof.m",         format: .vUnary,    match: 0x50012057, mask: 0xFC0FF07F, flags: [.vdNotVs2, .vdNotMask]),
        RV64InstrDesc(opcode: .vmsif_m,         mnemonic: "vmsif.m",         format: .vUnary,    match: 0x5001A057, mask: 0xFC0FF07F, flags: [.vdNotVs2, .vdNotMask]),
        RV64InstrDesc(opcode: .viota_m,         mnemonic: "viota.m",         format: .vUnary,    match: 0x50082057, mask: 0xFC0FF07F, flags: [.vdNotVs2, .vdNotMask]),
        RV64InstrDesc(opcode: .vid_v,           mnemonic: "vid.v",           format: .vNullary,  match: 0x5008A057, mask: 0xFDFFF07F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vcompress_vm,    mnemonic: "vcompress.vm",    format: .vVV,       match: 0x5E002057, mask: 0xFE00707F, flags: [.vdNotVs2, .vdNotVs1]),
        RV64InstrDesc(opcode: .vmandn_mm,       mnemonic: "vmandn.mm",       format: .vVV,       match: 0x62002057, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .vmand_mm,        mnemonic: "vmand.mm",        format: .vVV,       match: 0x66002057, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .vmor_mm,         mnemonic: "vmor.mm",         format: .vVV,       match: 0x6A002057, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .vmxor_mm,        mnemonic: "vmxor.mm",        format: .vVV,       match: 0x6E002057, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .vmorn_mm,        mnemonic: "vmorn.mm",        format: .vVV,       match: 0x72002057, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .vmnand_mm,       mnemonic: "vmnand.mm",       format: .vVV,       match: 0x76002057, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .vmnor_mm,        mnemonic: "vmnor.mm",        format: .vVV,       match: 0x7A002057, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .vmxnor_mm,       mnemonic: "vmxnor.mm",       format: .vVV,       match: 0x7E002057, mask: 0xFE00707F),
        RV64InstrDesc(opcode: .vdivu_vv,        mnemonic: "vdivu.vv",        format: .vVV,       match: 0x80002057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vdivu_vx,        mnemonic: "vdivu.vx",        format: .vVX,       match: 0x80006057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vdiv_vv,         mnemonic: "vdiv.vv",         format: .vVV,       match: 0x84002057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vdiv_vx,         mnemonic: "vdiv.vx",         format: .vVX,       match: 0x84006057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vremu_vv,        mnemonic: "vremu.vv",        format: .vVV,       match: 0x88002057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vremu_vx,        mnemonic: "vremu.vx",        format: .vVX,       match: 0x88006057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vrem_vv,         mnemonic: "vrem.vv",         format: .vVV,       match: 0x8C002057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vrem_vx,         mnemonic: "vrem.vx",         format: .vVX,       match: 0x8C006057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vmulhu_vv,       mnemonic: "vmulhu.vv",       format: .vVV,       match: 0x90002057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vmulhu_vx,       mnemonic: "vmulhu.vx",       format: .vVX,       match: 0x90006057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vmul_vv,         mnemonic: "vmul.vv",         format: .vVV,       match: 0x94002057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vmul_vx,         mnemonic: "vmul.vx",         format: .vVX,       match: 0x94006057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vmulhsu_vv,      mnemonic: "vmulhsu.vv",      format: .vVV,       match: 0x98002057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vmulhsu_vx,      mnemonic: "vmulhsu.vx",      format: .vVX,       match: 0x98006057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vmulh_vv,        mnemonic: "vmulh.vv",        format: .vVV,       match: 0x9C002057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vmulh_vx,        mnemonic: "vmulh.vx",        format: .vVX,       match: 0x9C006057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vmadd_vv,        mnemonic: "vmadd.vv",        format: .vMAccVV,   match: 0xA4002057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vmadd_vx,        mnemonic: "vmadd.vx",        format: .vMAccVX,   match: 0xA4006057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vnmsub_vv,       mnemonic: "vnmsub.vv",       format: .vMAccVV,   match: 0xAC002057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vnmsub_vx,       mnemonic: "vnmsub.vx",       format: .vMAccVX,   match: 0xAC006057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vmacc_vv,        mnemonic: "vmacc.vv",        format: .vMAccVV,   match: 0xB4002057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vmacc_vx,        mnemonic: "vmacc.vx",        format: .vMAccVX,   match: 0xB4006057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vnmsac_vv,       mnemonic: "vnmsac.vv",       format: .vMAccVV,   match: 0xBC002057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vnmsac_vx,       mnemonic: "vnmsac.vx",       format: .vMAccVX,   match: 0xBC006057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vwaddu_vv,       mnemonic: "vwaddu.vv",       format: .vVV,       match: 0xC0002057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vwaddu_vx,       mnemonic: "vwaddu.vx",       format: .vVX,       match: 0xC0006057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vwadd_vv,        mnemonic: "vwadd.vv",        format: .vVV,       match: 0xC4002057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vwadd_vx,        mnemonic: "vwadd.vx",        format: .vVX,       match: 0xC4006057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vwsubu_vv,       mnemonic: "vwsubu.vv",       format: .vVV,       match: 0xC8002057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vwsubu_vx,       mnemonic: "vwsubu.vx",       format: .vVX,       match: 0xC8006057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vwsub_vv,        mnemonic: "vwsub.vv",        format: .vVV,       match: 0xCC002057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vwsub_vx,        mnemonic: "vwsub.vx",        format: .vVX,       match: 0xCC006057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vwaddu_wv,       mnemonic: "vwaddu.wv",       format: .vVV,       match: 0xD0002057, mask: 0xFC00707F, flags: [.vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vwaddu_wx,       mnemonic: "vwaddu.wx",       format: .vVX,       match: 0xD0006057, mask: 0xFC00707F, flags: [.vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vwadd_wv,        mnemonic: "vwadd.wv",        format: .vVV,       match: 0xD4002057, mask: 0xFC00707F, flags: [.vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vwadd_wx,        mnemonic: "vwadd.wx",        format: .vVX,       match: 0xD4006057, mask: 0xFC00707F, flags: [.vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vwsubu_wv,       mnemonic: "vwsubu.wv",       format: .vVV,       match: 0xD8002057, mask: 0xFC00707F, flags: [.vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vwsubu_wx,       mnemonic: "vwsubu.wx",       format: .vVX,       match: 0xD8006057, mask: 0xFC00707F, flags: [.vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vwsub_wv,        mnemonic: "vwsub.wv",        format: .vVV,       match: 0xDC002057, mask: 0xFC00707F, flags: [.vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vwsub_wx,        mnemonic: "vwsub.wx",        format: .vVX,       match: 0xDC006057, mask: 0xFC00707F, flags: [.vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vwmulu_vv,       mnemonic: "vwmulu.vv",       format: .vVV,       match: 0xE0002057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vwmulu_vx,       mnemonic: "vwmulu.vx",       format: .vVX,       match: 0xE0006057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vwmulsu_vv,      mnemonic: "vwmulsu.vv",      format: .vVV,       match: 0xE8002057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vwmulsu_vx,      mnemonic: "vwmulsu.vx",      format: .vVX,       match: 0xE8006057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vwmul_vv,        mnemonic: "vwmul.vv",        format: .vVV,       match: 0xEC002057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vwmul_vx,        mnemonic: "vwmul.vx",        format: .vVX,       match: 0xEC006057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vwmaccu_vv,      mnemonic: "vwmaccu.vv",      format: .vMAccVV,   match: 0xF0002057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vwmaccu_vx,      mnemonic: "vwmaccu.vx",      format: .vMAccVX,   match: 0xF0006057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vwmacc_vv,       mnemonic: "vwmacc.vv",       format: .vMAccVV,   match: 0xF4002057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vwmacc_vx,       mnemonic: "vwmacc.vx",       format: .vMAccVX,   match: 0xF4006057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vwmaccus_vx,     mnemonic: "vwmaccus.vx",     format: .vMAccVX,   match: 0xF8006057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vwmaccsu_vv,     mnemonic: "vwmaccsu.vv",     format: .vMAccVV,   match: 0xFC002057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vwmaccsu_vx,     mnemonic: "vwmaccsu.vx",     format: .vMAccVX,   match: 0xFC006057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),

        // --- RVV floating-point (OPFVV/OPFVF) ---
        RV64InstrDesc(opcode: .vfadd_vv,           mnemonic: "vfadd.vv",           format: .vVV,      match: 0x00001057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfadd_vf,           mnemonic: "vfadd.vf",           format: .vVF,      match: 0x00005057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfredusum_vs,       mnemonic: "vfredusum.vs",       format: .vVV,      match: 0x04001057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vfsub_vv,           mnemonic: "vfsub.vv",           format: .vVV,      match: 0x08001057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfsub_vf,           mnemonic: "vfsub.vf",           format: .vVF,      match: 0x08005057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfredosum_vs,       mnemonic: "vfredosum.vs",       format: .vVV,      match: 0x0C001057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vfmin_vv,           mnemonic: "vfmin.vv",           format: .vVV,      match: 0x10001057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfmin_vf,           mnemonic: "vfmin.vf",           format: .vVF,      match: 0x10005057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfredmin_vs,        mnemonic: "vfredmin.vs",        format: .vVV,      match: 0x14001057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vfmax_vv,           mnemonic: "vfmax.vv",           format: .vVV,      match: 0x18001057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfmax_vf,           mnemonic: "vfmax.vf",           format: .vVF,      match: 0x18005057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfredmax_vs,        mnemonic: "vfredmax.vs",        format: .vVV,      match: 0x1C001057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vfsgnj_vv,          mnemonic: "vfsgnj.vv",          format: .vVV,      match: 0x20001057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfsgnj_vf,          mnemonic: "vfsgnj.vf",          format: .vVF,      match: 0x20005057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfsgnjn_vv,         mnemonic: "vfsgnjn.vv",         format: .vVV,      match: 0x24001057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfsgnjn_vf,         mnemonic: "vfsgnjn.vf",         format: .vVF,      match: 0x24005057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfsgnjx_vv,         mnemonic: "vfsgnjx.vv",         format: .vVV,      match: 0x28001057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfsgnjx_vf,         mnemonic: "vfsgnjx.vf",         format: .vVF,      match: 0x28005057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfslide1up_vf,      mnemonic: "vfslide1up.vf",      format: .vVF,      match: 0x38005057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotMask]),
        RV64InstrDesc(opcode: .vfslide1down_vf,    mnemonic: "vfslide1down.vf",    format: .vVF,      match: 0x3C005057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfmv_f_s,           mnemonic: "vfmv.f.s",           format: .vToF,     match: 0x42001057, mask: 0xFE0FF07F),
        RV64InstrDesc(opcode: .vfmv_s_f,           mnemonic: "vfmv.s.f",           format: .vMvVF,    match: 0x42005057, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .vfcvt_xu_f_v,       mnemonic: "vfcvt.xu.f.v",       format: .vUnary,   match: 0x48001057, mask: 0xFC0FF07F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfcvt_x_f_v,        mnemonic: "vfcvt.x.f.v",        format: .vUnary,   match: 0x48009057, mask: 0xFC0FF07F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfcvt_f_xu_v,       mnemonic: "vfcvt.f.xu.v",       format: .vUnary,   match: 0x48011057, mask: 0xFC0FF07F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfcvt_f_x_v,        mnemonic: "vfcvt.f.x.v",        format: .vUnary,   match: 0x48019057, mask: 0xFC0FF07F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfcvt_rtz_xu_f_v,   mnemonic: "vfcvt.rtz.xu.f.v",   format: .vUnary,   match: 0x48031057, mask: 0xFC0FF07F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfcvt_rtz_x_f_v,    mnemonic: "vfcvt.rtz.x.f.v",    format: .vUnary,   match: 0x48039057, mask: 0xFC0FF07F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfwcvt_xu_f_v,      mnemonic: "vfwcvt.xu.f.v",      format: .vUnary,   match: 0x48041057, mask: 0xFC0FF07F, flags: [.vdNotVs2, .vdNotMask]),
        RV64InstrDesc(opcode: .vfwcvt_x_f_v,       mnemonic: "vfwcvt.x.f.v",       format: .vUnary,   match: 0x48049057, mask: 0xFC0FF07F, flags: [.vdNotVs2, .vdNotMask]),
        RV64InstrDesc(opcode: .vfwcvt_f_xu_v,      mnemonic: "vfwcvt.f.xu.v",      format: .vUnary,   match: 0x48051057, mask: 0xFC0FF07F, flags: [.vdNotVs2, .vdNotMask]),
        RV64InstrDesc(opcode: .vfwcvt_f_x_v,       mnemonic: "vfwcvt.f.x.v",       format: .vUnary,   match: 0x48059057, mask: 0xFC0FF07F, flags: [.vdNotVs2, .vdNotMask]),
        RV64InstrDesc(opcode: .vfwcvt_f_f_v,       mnemonic: "vfwcvt.f.f.v",       format: .vUnary,   match: 0x48061057, mask: 0xFC0FF07F, flags: [.vdNotVs2, .vdNotMask]),
        RV64InstrDesc(opcode: .vfwcvt_rtz_xu_f_v,  mnemonic: "vfwcvt.rtz.xu.f.v",  format: .vUnary,   match: 0x48071057, mask: 0xFC0FF07F, flags: [.vdNotVs2, .vdNotMask]),
        RV64InstrDesc(opcode: .vfwcvt_rtz_x_f_v,   mnemonic: "vfwcvt.rtz.x.f.v",   format: .vUnary,   match: 0x48079057, mask: 0xFC0FF07F, flags: [.vdNotVs2, .vdNotMask]),
        RV64InstrDesc(opcode: .vfncvt_xu_f_w,      mnemonic: "vfncvt.xu.f.w",      format: .vUnary,   match: 0x48081057, mask: 0xFC0FF07F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfncvt_x_f_w,       mnemonic: "vfncvt.x.f.w",       format: .vUnary,   match: 0x48089057, mask: 0xFC0FF07F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfncvt_f_xu_w,      mnemonic: "vfncvt.f.xu.w",      format: .vUnary,   match: 0x48091057, mask: 0xFC0FF07F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfncvt_f_x_w,       mnemonic: "vfncvt.f.x.w",       format: .vUnary,   match: 0x48099057, mask: 0xFC0FF07F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfncvt_f_f_w,       mnemonic: "vfncvt.f.f.w",       format: .vUnary,   match: 0x480A1057, mask: 0xFC0FF07F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfncvt_rod_f_f_w,   mnemonic: "vfncvt.rod.f.f.w",   format: .vUnary,   match: 0x480A9057, mask: 0xFC0FF07F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfncvt_rtz_xu_f_w,  mnemonic: "vfncvt.rtz.xu.f.w",  format: .vUnary,   match: 0x480B1057, mask: 0xFC0FF07F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfncvt_rtz_x_f_w,   mnemonic: "vfncvt.rtz.x.f.w",   format: .vUnary,   match: 0x480B9057, mask: 0xFC0FF07F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfsqrt_v,           mnemonic: "vfsqrt.v",           format: .vUnary,   match: 0x4C001057, mask: 0xFC0FF07F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfrsqrt7_v,         mnemonic: "vfrsqrt7.v",         format: .vUnary,   match: 0x4C021057, mask: 0xFC0FF07F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfrec7_v,           mnemonic: "vfrec7.v",           format: .vUnary,   match: 0x4C029057, mask: 0xFC0FF07F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfclass_v,          mnemonic: "vfclass.v",          format: .vUnary,   match: 0x4C081057, mask: 0xFC0FF07F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfmerge_vfm,        mnemonic: "vfmerge.vfm",        format: .vVF,      match: 0x5C005057, mask: 0xFE00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfmv_v_f,           mnemonic: "vfmv.v.f",           format: .vMvVF,    match: 0x5E005057, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .vmfeq_vv,           mnemonic: "vmfeq.vv",           format: .vVV,      match: 0x60001057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vmfeq_vf,           mnemonic: "vmfeq.vf",           format: .vVF,      match: 0x60005057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vmfle_vv,           mnemonic: "vmfle.vv",           format: .vVV,      match: 0x64001057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vmfle_vf,           mnemonic: "vmfle.vf",           format: .vVF,      match: 0x64005057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vmflt_vv,           mnemonic: "vmflt.vv",           format: .vVV,      match: 0x6C001057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vmflt_vf,           mnemonic: "vmflt.vf",           format: .vVF,      match: 0x6C005057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vmfne_vv,           mnemonic: "vmfne.vv",           format: .vVV,      match: 0x70001057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vmfne_vf,           mnemonic: "vmfne.vf",           format: .vVF,      match: 0x70005057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vmfgt_vf,           mnemonic: "vmfgt.vf",           format: .vVF,      match: 0x74005057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vmfge_vf,           mnemonic: "vmfge.vf",           format: .vVF,      match: 0x7C005057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vfdiv_vv,           mnemonic: "vfdiv.vv",           format: .vVV,      match: 0x80001057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfdiv_vf,           mnemonic: "vfdiv.vf",           format: .vVF,      match: 0x80005057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfrdiv_vf,          mnemonic: "vfrdiv.vf",          format: .vVF,      match: 0x84005057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfmul_vv,           mnemonic: "vfmul.vv",           format: .vVV,      match: 0x90001057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfmul_vf,           mnemonic: "vfmul.vf",           format: .vVF,      match: 0x90005057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfrsub_vf,          mnemonic: "vfrsub.vf",          format: .vVF,      match: 0x9C005057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfmadd_vv,          mnemonic: "vfmadd.vv",          format: .vMAccVV,  match: 0xA0001057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfmadd_vf,          mnemonic: "vfmadd.vf",          format: .vMAccVF,  match: 0xA0005057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfnmadd_vv,         mnemonic: "vfnmadd.vv",         format: .vMAccVV,  match: 0xA4001057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfnmadd_vf,         mnemonic: "vfnmadd.vf",         format: .vMAccVF,  match: 0xA4005057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfmsub_vv,          mnemonic: "vfmsub.vv",          format: .vMAccVV,  match: 0xA8001057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfmsub_vf,          mnemonic: "vfmsub.vf",          format: .vMAccVF,  match: 0xA8005057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfnmsub_vv,         mnemonic: "vfnmsub.vv",         format: .vMAccVV,  match: 0xAC001057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfnmsub_vf,         mnemonic: "vfnmsub.vf",         format: .vMAccVF,  match: 0xAC005057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfmacc_vv,          mnemonic: "vfmacc.vv",          format: .vMAccVV,  match: 0xB0001057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfmacc_vf,          mnemonic: "vfmacc.vf",          format: .vMAccVF,  match: 0xB0005057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfnmacc_vv,         mnemonic: "vfnmacc.vv",         format: .vMAccVV,  match: 0xB4001057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfnmacc_vf,         mnemonic: "vfnmacc.vf",         format: .vMAccVF,  match: 0xB4005057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfmsac_vv,          mnemonic: "vfmsac.vv",          format: .vMAccVV,  match: 0xB8001057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfmsac_vf,          mnemonic: "vfmsac.vf",          format: .vMAccVF,  match: 0xB8005057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfnmsac_vv,         mnemonic: "vfnmsac.vv",         format: .vMAccVV,  match: 0xBC001057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfnmsac_vf,         mnemonic: "vfnmsac.vf",         format: .vMAccVF,  match: 0xBC005057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vfwadd_vv,          mnemonic: "vfwadd.vv",          format: .vVV,      match: 0xC0001057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vfwadd_vf,          mnemonic: "vfwadd.vf",          format: .vVF,      match: 0xC0005057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vfwredusum_vs,      mnemonic: "vfwredusum.vs",      format: .vVV,      match: 0xC4001057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vfwsub_vv,          mnemonic: "vfwsub.vv",          format: .vVV,      match: 0xC8001057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vfwsub_vf,          mnemonic: "vfwsub.vf",          format: .vVF,      match: 0xC8005057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vfwredosum_vs,      mnemonic: "vfwredosum.vs",      format: .vVV,      match: 0xCC001057, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vfwadd_wv,          mnemonic: "vfwadd.wv",          format: .vVV,      match: 0xD0001057, mask: 0xFC00707F, flags: [.vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vfwadd_wf,          mnemonic: "vfwadd.wf",          format: .vVF,      match: 0xD0005057, mask: 0xFC00707F, flags: [.vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vfwsub_wv,          mnemonic: "vfwsub.wv",          format: .vVV,      match: 0xD8001057, mask: 0xFC00707F, flags: [.vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vfwsub_wf,          mnemonic: "vfwsub.wf",          format: .vVF,      match: 0xD8005057, mask: 0xFC00707F, flags: [.vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vfwmul_vv,          mnemonic: "vfwmul.vv",          format: .vVV,      match: 0xE0001057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vfwmul_vf,          mnemonic: "vfwmul.vf",          format: .vVF,      match: 0xE0005057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vfwmacc_vv,         mnemonic: "vfwmacc.vv",         format: .vMAccVV,  match: 0xF0001057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vfwmacc_vf,         mnemonic: "vfwmacc.vf",         format: .vMAccVF,  match: 0xF0005057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vfwnmacc_vv,        mnemonic: "vfwnmacc.vv",        format: .vMAccVV,  match: 0xF4001057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vfwnmacc_vf,        mnemonic: "vfwnmacc.vf",        format: .vMAccVF,  match: 0xF4005057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vfwmsac_vv,         mnemonic: "vfwmsac.vv",         format: .vMAccVV,  match: 0xF8001057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vfwmsac_vf,         mnemonic: "vfwmsac.vf",         format: .vMAccVF,  match: 0xF8005057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vfwnmsac_vv,        mnemonic: "vfwnmsac.vv",        format: .vMAccVV,  match: 0xFC001057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vfwnmsac_vf,        mnemonic: "vfwnmsac.vf",        format: .vMAccVF,  match: 0xFC005057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),

        // --- Zvbb & Zvkb (vector basic bit-manipulation) ---
        RV64InstrDesc(opcode: .vandn_vv,  mnemonic: "vandn.vv",  format: .vVV,     match: 0x04000057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vandn_vx,  mnemonic: "vandn.vx",  format: .vVX,     match: 0x04004057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vbrev8_v,  mnemonic: "vbrev8.v",  format: .vUnary,  match: 0x48042057, mask: 0xFC0FF07F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vrev8_v,   mnemonic: "vrev8.v",   format: .vUnary,  match: 0x4804A057, mask: 0xFC0FF07F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vbrev_v,   mnemonic: "vbrev.v",   format: .vUnary,  match: 0x48052057, mask: 0xFC0FF07F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vclz_v,    mnemonic: "vclz.v",    format: .vUnary,  match: 0x48062057, mask: 0xFC0FF07F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vctz_v,    mnemonic: "vctz.v",    format: .vUnary,  match: 0x4806A057, mask: 0xFC0FF07F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vcpop_v,   mnemonic: "vcpop.v",   format: .vUnary,  match: 0x48072057, mask: 0xFC0FF07F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vrol_vv,   mnemonic: "vrol.vv",   format: .vVV,     match: 0x54000057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vrol_vx,   mnemonic: "vrol.vx",   format: .vVX,     match: 0x54004057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vror_vv,   mnemonic: "vror.vv",   format: .vVV,     match: 0x50000057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vror_vx,   mnemonic: "vror.vx",   format: .vVX,     match: 0x50004057, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vror_vi,   mnemonic: "vror.vi",   format: .vVUI6,   match: 0x50003057, mask: 0xF800707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vwsll_vv,  mnemonic: "vwsll.vv",  format: .vVV,     match: 0xD4000057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vwsll_vx,  mnemonic: "vwsll.vx",  format: .vVX,     match: 0xD4004057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),
        RV64InstrDesc(opcode: .vwsll_vi,  mnemonic: "vwsll.vi",  format: .vVUI,    match: 0xD4003057, mask: 0xFC00707F, flags: [.vdNotVs2, .vdNotVs1, .vdNotMask]),

        // --- RVV loads & stores ---
        RV64InstrDesc(opcode: .vle8_v,      mnemonic: "vle8.v",      format: .vLoadUnit,      match: 0x00000007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vse8_v,      mnemonic: "vse8.v",      format: .vStoreUnit,     match: 0x00000027, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vle8ff_v,    mnemonic: "vle8ff.v",    format: .vLoadUnit,      match: 0x01000007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vlse8_v,     mnemonic: "vlse8.v",     format: .vLoadStrided,   match: 0x08000007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsse8_v,     mnemonic: "vsse8.v",     format: .vStoreStrided,  match: 0x08000027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vluxei8_v,   mnemonic: "vluxei8.v",   format: .vLoadIndexed,   match: 0x04000007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vloxei8_v,   mnemonic: "vloxei8.v",   format: .vLoadIndexed,   match: 0x0C000007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsuxei8_v,   mnemonic: "vsuxei8.v",   format: .vStoreIndexed,  match: 0x04000027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vsoxei8_v,   mnemonic: "vsoxei8.v",   format: .vStoreIndexed,  match: 0x0C000027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vle16_v,     mnemonic: "vle16.v",     format: .vLoadUnit,      match: 0x00005007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vse16_v,     mnemonic: "vse16.v",     format: .vStoreUnit,     match: 0x00005027, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vle16ff_v,   mnemonic: "vle16ff.v",   format: .vLoadUnit,      match: 0x01005007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vlse16_v,    mnemonic: "vlse16.v",    format: .vLoadStrided,   match: 0x08005007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsse16_v,    mnemonic: "vsse16.v",    format: .vStoreStrided,  match: 0x08005027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vluxei16_v,  mnemonic: "vluxei16.v",  format: .vLoadIndexed,   match: 0x04005007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vloxei16_v,  mnemonic: "vloxei16.v",  format: .vLoadIndexed,   match: 0x0C005007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsuxei16_v,  mnemonic: "vsuxei16.v",  format: .vStoreIndexed,  match: 0x04005027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vsoxei16_v,  mnemonic: "vsoxei16.v",  format: .vStoreIndexed,  match: 0x0C005027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vle32_v,     mnemonic: "vle32.v",     format: .vLoadUnit,      match: 0x00006007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vse32_v,     mnemonic: "vse32.v",     format: .vStoreUnit,     match: 0x00006027, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vle32ff_v,   mnemonic: "vle32ff.v",   format: .vLoadUnit,      match: 0x01006007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vlse32_v,    mnemonic: "vlse32.v",    format: .vLoadStrided,   match: 0x08006007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsse32_v,    mnemonic: "vsse32.v",    format: .vStoreStrided,  match: 0x08006027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vluxei32_v,  mnemonic: "vluxei32.v",  format: .vLoadIndexed,   match: 0x04006007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vloxei32_v,  mnemonic: "vloxei32.v",  format: .vLoadIndexed,   match: 0x0C006007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsuxei32_v,  mnemonic: "vsuxei32.v",  format: .vStoreIndexed,  match: 0x04006027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vsoxei32_v,  mnemonic: "vsoxei32.v",  format: .vStoreIndexed,  match: 0x0C006027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vle64_v,     mnemonic: "vle64.v",     format: .vLoadUnit,      match: 0x00007007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vse64_v,     mnemonic: "vse64.v",     format: .vStoreUnit,     match: 0x00007027, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vle64ff_v,   mnemonic: "vle64ff.v",   format: .vLoadUnit,      match: 0x01007007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vlse64_v,    mnemonic: "vlse64.v",    format: .vLoadStrided,   match: 0x08007007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsse64_v,    mnemonic: "vsse64.v",    format: .vStoreStrided,  match: 0x08007027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vluxei64_v,  mnemonic: "vluxei64.v",  format: .vLoadIndexed,   match: 0x04007007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vloxei64_v,  mnemonic: "vloxei64.v",  format: .vLoadIndexed,   match: 0x0C007007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsuxei64_v,  mnemonic: "vsuxei64.v",  format: .vStoreIndexed,  match: 0x04007027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vsoxei64_v,  mnemonic: "vsoxei64.v",  format: .vStoreIndexed,  match: 0x0C007027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vlm_v,       mnemonic: "vlm.v",       format: .vLoadUnit,      match: 0x02B00007, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .vsm_v,       mnemonic: "vsm.v",       format: .vStoreUnit,     match: 0x02B00027, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .vl1re8_v,    mnemonic: "vl1re8.v",    format: .vLoadWhole,     match: 0x02800007, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .vl1re16_v,   mnemonic: "vl1re16.v",   format: .vLoadWhole,     match: 0x02805007, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .vl1re32_v,   mnemonic: "vl1re32.v",   format: .vLoadWhole,     match: 0x02806007, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .vl1re64_v,   mnemonic: "vl1re64.v",   format: .vLoadWhole,     match: 0x02807007, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .vs1r_v,      mnemonic: "vs1r.v",      format: .vStoreWhole,    match: 0x02800027, mask: 0xFFF0707F),
        RV64InstrDesc(opcode: .vl2re8_v,    mnemonic: "vl2re8.v",    format: .vLoadWhole,     match: 0x22800007, mask: 0xFFF0707F, flags: [.group2]),
        RV64InstrDesc(opcode: .vl2re16_v,   mnemonic: "vl2re16.v",   format: .vLoadWhole,     match: 0x22805007, mask: 0xFFF0707F, flags: [.group2]),
        RV64InstrDesc(opcode: .vl2re32_v,   mnemonic: "vl2re32.v",   format: .vLoadWhole,     match: 0x22806007, mask: 0xFFF0707F, flags: [.group2]),
        RV64InstrDesc(opcode: .vl2re64_v,   mnemonic: "vl2re64.v",   format: .vLoadWhole,     match: 0x22807007, mask: 0xFFF0707F, flags: [.group2]),
        RV64InstrDesc(opcode: .vs2r_v,      mnemonic: "vs2r.v",      format: .vStoreWhole,    match: 0x22800027, mask: 0xFFF0707F, flags: [.group2]),
        RV64InstrDesc(opcode: .vl4re8_v,    mnemonic: "vl4re8.v",    format: .vLoadWhole,     match: 0x62800007, mask: 0xFFF0707F, flags: [.group4]),
        RV64InstrDesc(opcode: .vl4re16_v,   mnemonic: "vl4re16.v",   format: .vLoadWhole,     match: 0x62805007, mask: 0xFFF0707F, flags: [.group4]),
        RV64InstrDesc(opcode: .vl4re32_v,   mnemonic: "vl4re32.v",   format: .vLoadWhole,     match: 0x62806007, mask: 0xFFF0707F, flags: [.group4]),
        RV64InstrDesc(opcode: .vl4re64_v,   mnemonic: "vl4re64.v",   format: .vLoadWhole,     match: 0x62807007, mask: 0xFFF0707F, flags: [.group4]),
        RV64InstrDesc(opcode: .vs4r_v,      mnemonic: "vs4r.v",      format: .vStoreWhole,    match: 0x62800027, mask: 0xFFF0707F, flags: [.group4]),
        RV64InstrDesc(opcode: .vl8re8_v,    mnemonic: "vl8re8.v",    format: .vLoadWhole,     match: 0xE2800007, mask: 0xFFF0707F, flags: [.group8]),
        RV64InstrDesc(opcode: .vl8re16_v,   mnemonic: "vl8re16.v",   format: .vLoadWhole,     match: 0xE2805007, mask: 0xFFF0707F, flags: [.group8]),
        RV64InstrDesc(opcode: .vl8re32_v,   mnemonic: "vl8re32.v",   format: .vLoadWhole,     match: 0xE2806007, mask: 0xFFF0707F, flags: [.group8]),
        RV64InstrDesc(opcode: .vl8re64_v,   mnemonic: "vl8re64.v",   format: .vLoadWhole,     match: 0xE2807007, mask: 0xFFF0707F, flags: [.group8]),
        RV64InstrDesc(opcode: .vs8r_v,      mnemonic: "vs8r.v",      format: .vStoreWhole,    match: 0xE2800027, mask: 0xFFF0707F, flags: [.group8]),

        // --- RVV segment loads & stores ---
        RV64InstrDesc(opcode: .vlseg2e8_v,      mnemonic: "vlseg2e8.v",      format: .vLoadUnit,      match: 0x20000007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsseg2e8_v,      mnemonic: "vsseg2e8.v",      format: .vStoreUnit,     match: 0x20000027, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vlseg2e8ff_v,    mnemonic: "vlseg2e8ff.v",    format: .vLoadUnit,      match: 0x21000007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vlsseg2e8_v,     mnemonic: "vlsseg2e8.v",     format: .vLoadStrided,   match: 0x28000007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssseg2e8_v,     mnemonic: "vssseg2e8.v",     format: .vStoreStrided,  match: 0x28000027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vluxseg2ei8_v,   mnemonic: "vluxseg2ei8.v",   format: .vLoadIndexed,   match: 0x24000007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vloxseg2ei8_v,   mnemonic: "vloxseg2ei8.v",   format: .vLoadIndexed,   match: 0x2C000007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsuxseg2ei8_v,   mnemonic: "vsuxseg2ei8.v",   format: .vStoreIndexed,  match: 0x24000027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vsoxseg2ei8_v,   mnemonic: "vsoxseg2ei8.v",   format: .vStoreIndexed,  match: 0x2C000027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vlseg2e16_v,     mnemonic: "vlseg2e16.v",     format: .vLoadUnit,      match: 0x20005007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsseg2e16_v,     mnemonic: "vsseg2e16.v",     format: .vStoreUnit,     match: 0x20005027, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vlseg2e16ff_v,   mnemonic: "vlseg2e16ff.v",   format: .vLoadUnit,      match: 0x21005007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vlsseg2e16_v,    mnemonic: "vlsseg2e16.v",    format: .vLoadStrided,   match: 0x28005007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssseg2e16_v,    mnemonic: "vssseg2e16.v",    format: .vStoreStrided,  match: 0x28005027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vluxseg2ei16_v,  mnemonic: "vluxseg2ei16.v",  format: .vLoadIndexed,   match: 0x24005007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vloxseg2ei16_v,  mnemonic: "vloxseg2ei16.v",  format: .vLoadIndexed,   match: 0x2C005007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsuxseg2ei16_v,  mnemonic: "vsuxseg2ei16.v",  format: .vStoreIndexed,  match: 0x24005027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vsoxseg2ei16_v,  mnemonic: "vsoxseg2ei16.v",  format: .vStoreIndexed,  match: 0x2C005027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vlseg2e32_v,     mnemonic: "vlseg2e32.v",     format: .vLoadUnit,      match: 0x20006007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsseg2e32_v,     mnemonic: "vsseg2e32.v",     format: .vStoreUnit,     match: 0x20006027, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vlseg2e32ff_v,   mnemonic: "vlseg2e32ff.v",   format: .vLoadUnit,      match: 0x21006007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vlsseg2e32_v,    mnemonic: "vlsseg2e32.v",    format: .vLoadStrided,   match: 0x28006007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssseg2e32_v,    mnemonic: "vssseg2e32.v",    format: .vStoreStrided,  match: 0x28006027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vluxseg2ei32_v,  mnemonic: "vluxseg2ei32.v",  format: .vLoadIndexed,   match: 0x24006007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vloxseg2ei32_v,  mnemonic: "vloxseg2ei32.v",  format: .vLoadIndexed,   match: 0x2C006007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsuxseg2ei32_v,  mnemonic: "vsuxseg2ei32.v",  format: .vStoreIndexed,  match: 0x24006027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vsoxseg2ei32_v,  mnemonic: "vsoxseg2ei32.v",  format: .vStoreIndexed,  match: 0x2C006027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vlseg2e64_v,     mnemonic: "vlseg2e64.v",     format: .vLoadUnit,      match: 0x20007007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsseg2e64_v,     mnemonic: "vsseg2e64.v",     format: .vStoreUnit,     match: 0x20007027, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vlseg2e64ff_v,   mnemonic: "vlseg2e64ff.v",   format: .vLoadUnit,      match: 0x21007007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vlsseg2e64_v,    mnemonic: "vlsseg2e64.v",    format: .vLoadStrided,   match: 0x28007007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssseg2e64_v,    mnemonic: "vssseg2e64.v",    format: .vStoreStrided,  match: 0x28007027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vluxseg2ei64_v,  mnemonic: "vluxseg2ei64.v",  format: .vLoadIndexed,   match: 0x24007007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vloxseg2ei64_v,  mnemonic: "vloxseg2ei64.v",  format: .vLoadIndexed,   match: 0x2C007007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsuxseg2ei64_v,  mnemonic: "vsuxseg2ei64.v",  format: .vStoreIndexed,  match: 0x24007027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vsoxseg2ei64_v,  mnemonic: "vsoxseg2ei64.v",  format: .vStoreIndexed,  match: 0x2C007027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vlseg3e8_v,      mnemonic: "vlseg3e8.v",      format: .vLoadUnit,      match: 0x40000007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsseg3e8_v,      mnemonic: "vsseg3e8.v",      format: .vStoreUnit,     match: 0x40000027, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vlseg3e8ff_v,    mnemonic: "vlseg3e8ff.v",    format: .vLoadUnit,      match: 0x41000007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vlsseg3e8_v,     mnemonic: "vlsseg3e8.v",     format: .vLoadStrided,   match: 0x48000007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssseg3e8_v,     mnemonic: "vssseg3e8.v",     format: .vStoreStrided,  match: 0x48000027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vluxseg3ei8_v,   mnemonic: "vluxseg3ei8.v",   format: .vLoadIndexed,   match: 0x44000007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vloxseg3ei8_v,   mnemonic: "vloxseg3ei8.v",   format: .vLoadIndexed,   match: 0x4C000007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsuxseg3ei8_v,   mnemonic: "vsuxseg3ei8.v",   format: .vStoreIndexed,  match: 0x44000027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vsoxseg3ei8_v,   mnemonic: "vsoxseg3ei8.v",   format: .vStoreIndexed,  match: 0x4C000027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vlseg3e16_v,     mnemonic: "vlseg3e16.v",     format: .vLoadUnit,      match: 0x40005007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsseg3e16_v,     mnemonic: "vsseg3e16.v",     format: .vStoreUnit,     match: 0x40005027, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vlseg3e16ff_v,   mnemonic: "vlseg3e16ff.v",   format: .vLoadUnit,      match: 0x41005007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vlsseg3e16_v,    mnemonic: "vlsseg3e16.v",    format: .vLoadStrided,   match: 0x48005007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssseg3e16_v,    mnemonic: "vssseg3e16.v",    format: .vStoreStrided,  match: 0x48005027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vluxseg3ei16_v,  mnemonic: "vluxseg3ei16.v",  format: .vLoadIndexed,   match: 0x44005007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vloxseg3ei16_v,  mnemonic: "vloxseg3ei16.v",  format: .vLoadIndexed,   match: 0x4C005007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsuxseg3ei16_v,  mnemonic: "vsuxseg3ei16.v",  format: .vStoreIndexed,  match: 0x44005027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vsoxseg3ei16_v,  mnemonic: "vsoxseg3ei16.v",  format: .vStoreIndexed,  match: 0x4C005027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vlseg3e32_v,     mnemonic: "vlseg3e32.v",     format: .vLoadUnit,      match: 0x40006007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsseg3e32_v,     mnemonic: "vsseg3e32.v",     format: .vStoreUnit,     match: 0x40006027, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vlseg3e32ff_v,   mnemonic: "vlseg3e32ff.v",   format: .vLoadUnit,      match: 0x41006007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vlsseg3e32_v,    mnemonic: "vlsseg3e32.v",    format: .vLoadStrided,   match: 0x48006007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssseg3e32_v,    mnemonic: "vssseg3e32.v",    format: .vStoreStrided,  match: 0x48006027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vluxseg3ei32_v,  mnemonic: "vluxseg3ei32.v",  format: .vLoadIndexed,   match: 0x44006007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vloxseg3ei32_v,  mnemonic: "vloxseg3ei32.v",  format: .vLoadIndexed,   match: 0x4C006007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsuxseg3ei32_v,  mnemonic: "vsuxseg3ei32.v",  format: .vStoreIndexed,  match: 0x44006027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vsoxseg3ei32_v,  mnemonic: "vsoxseg3ei32.v",  format: .vStoreIndexed,  match: 0x4C006027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vlseg3e64_v,     mnemonic: "vlseg3e64.v",     format: .vLoadUnit,      match: 0x40007007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsseg3e64_v,     mnemonic: "vsseg3e64.v",     format: .vStoreUnit,     match: 0x40007027, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vlseg3e64ff_v,   mnemonic: "vlseg3e64ff.v",   format: .vLoadUnit,      match: 0x41007007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vlsseg3e64_v,    mnemonic: "vlsseg3e64.v",    format: .vLoadStrided,   match: 0x48007007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssseg3e64_v,    mnemonic: "vssseg3e64.v",    format: .vStoreStrided,  match: 0x48007027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vluxseg3ei64_v,  mnemonic: "vluxseg3ei64.v",  format: .vLoadIndexed,   match: 0x44007007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vloxseg3ei64_v,  mnemonic: "vloxseg3ei64.v",  format: .vLoadIndexed,   match: 0x4C007007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsuxseg3ei64_v,  mnemonic: "vsuxseg3ei64.v",  format: .vStoreIndexed,  match: 0x44007027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vsoxseg3ei64_v,  mnemonic: "vsoxseg3ei64.v",  format: .vStoreIndexed,  match: 0x4C007027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vlseg4e8_v,      mnemonic: "vlseg4e8.v",      format: .vLoadUnit,      match: 0x60000007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsseg4e8_v,      mnemonic: "vsseg4e8.v",      format: .vStoreUnit,     match: 0x60000027, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vlseg4e8ff_v,    mnemonic: "vlseg4e8ff.v",    format: .vLoadUnit,      match: 0x61000007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vlsseg4e8_v,     mnemonic: "vlsseg4e8.v",     format: .vLoadStrided,   match: 0x68000007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssseg4e8_v,     mnemonic: "vssseg4e8.v",     format: .vStoreStrided,  match: 0x68000027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vluxseg4ei8_v,   mnemonic: "vluxseg4ei8.v",   format: .vLoadIndexed,   match: 0x64000007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vloxseg4ei8_v,   mnemonic: "vloxseg4ei8.v",   format: .vLoadIndexed,   match: 0x6C000007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsuxseg4ei8_v,   mnemonic: "vsuxseg4ei8.v",   format: .vStoreIndexed,  match: 0x64000027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vsoxseg4ei8_v,   mnemonic: "vsoxseg4ei8.v",   format: .vStoreIndexed,  match: 0x6C000027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vlseg4e16_v,     mnemonic: "vlseg4e16.v",     format: .vLoadUnit,      match: 0x60005007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsseg4e16_v,     mnemonic: "vsseg4e16.v",     format: .vStoreUnit,     match: 0x60005027, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vlseg4e16ff_v,   mnemonic: "vlseg4e16ff.v",   format: .vLoadUnit,      match: 0x61005007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vlsseg4e16_v,    mnemonic: "vlsseg4e16.v",    format: .vLoadStrided,   match: 0x68005007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssseg4e16_v,    mnemonic: "vssseg4e16.v",    format: .vStoreStrided,  match: 0x68005027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vluxseg4ei16_v,  mnemonic: "vluxseg4ei16.v",  format: .vLoadIndexed,   match: 0x64005007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vloxseg4ei16_v,  mnemonic: "vloxseg4ei16.v",  format: .vLoadIndexed,   match: 0x6C005007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsuxseg4ei16_v,  mnemonic: "vsuxseg4ei16.v",  format: .vStoreIndexed,  match: 0x64005027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vsoxseg4ei16_v,  mnemonic: "vsoxseg4ei16.v",  format: .vStoreIndexed,  match: 0x6C005027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vlseg4e32_v,     mnemonic: "vlseg4e32.v",     format: .vLoadUnit,      match: 0x60006007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsseg4e32_v,     mnemonic: "vsseg4e32.v",     format: .vStoreUnit,     match: 0x60006027, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vlseg4e32ff_v,   mnemonic: "vlseg4e32ff.v",   format: .vLoadUnit,      match: 0x61006007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vlsseg4e32_v,    mnemonic: "vlsseg4e32.v",    format: .vLoadStrided,   match: 0x68006007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssseg4e32_v,    mnemonic: "vssseg4e32.v",    format: .vStoreStrided,  match: 0x68006027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vluxseg4ei32_v,  mnemonic: "vluxseg4ei32.v",  format: .vLoadIndexed,   match: 0x64006007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vloxseg4ei32_v,  mnemonic: "vloxseg4ei32.v",  format: .vLoadIndexed,   match: 0x6C006007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsuxseg4ei32_v,  mnemonic: "vsuxseg4ei32.v",  format: .vStoreIndexed,  match: 0x64006027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vsoxseg4ei32_v,  mnemonic: "vsoxseg4ei32.v",  format: .vStoreIndexed,  match: 0x6C006027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vlseg4e64_v,     mnemonic: "vlseg4e64.v",     format: .vLoadUnit,      match: 0x60007007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsseg4e64_v,     mnemonic: "vsseg4e64.v",     format: .vStoreUnit,     match: 0x60007027, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vlseg4e64ff_v,   mnemonic: "vlseg4e64ff.v",   format: .vLoadUnit,      match: 0x61007007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vlsseg4e64_v,    mnemonic: "vlsseg4e64.v",    format: .vLoadStrided,   match: 0x68007007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssseg4e64_v,    mnemonic: "vssseg4e64.v",    format: .vStoreStrided,  match: 0x68007027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vluxseg4ei64_v,  mnemonic: "vluxseg4ei64.v",  format: .vLoadIndexed,   match: 0x64007007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vloxseg4ei64_v,  mnemonic: "vloxseg4ei64.v",  format: .vLoadIndexed,   match: 0x6C007007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsuxseg4ei64_v,  mnemonic: "vsuxseg4ei64.v",  format: .vStoreIndexed,  match: 0x64007027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vsoxseg4ei64_v,  mnemonic: "vsoxseg4ei64.v",  format: .vStoreIndexed,  match: 0x6C007027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vlseg5e8_v,      mnemonic: "vlseg5e8.v",      format: .vLoadUnit,      match: 0x80000007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsseg5e8_v,      mnemonic: "vsseg5e8.v",      format: .vStoreUnit,     match: 0x80000027, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vlseg5e8ff_v,    mnemonic: "vlseg5e8ff.v",    format: .vLoadUnit,      match: 0x81000007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vlsseg5e8_v,     mnemonic: "vlsseg5e8.v",     format: .vLoadStrided,   match: 0x88000007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssseg5e8_v,     mnemonic: "vssseg5e8.v",     format: .vStoreStrided,  match: 0x88000027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vluxseg5ei8_v,   mnemonic: "vluxseg5ei8.v",   format: .vLoadIndexed,   match: 0x84000007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vloxseg5ei8_v,   mnemonic: "vloxseg5ei8.v",   format: .vLoadIndexed,   match: 0x8C000007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsuxseg5ei8_v,   mnemonic: "vsuxseg5ei8.v",   format: .vStoreIndexed,  match: 0x84000027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vsoxseg5ei8_v,   mnemonic: "vsoxseg5ei8.v",   format: .vStoreIndexed,  match: 0x8C000027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vlseg5e16_v,     mnemonic: "vlseg5e16.v",     format: .vLoadUnit,      match: 0x80005007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsseg5e16_v,     mnemonic: "vsseg5e16.v",     format: .vStoreUnit,     match: 0x80005027, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vlseg5e16ff_v,   mnemonic: "vlseg5e16ff.v",   format: .vLoadUnit,      match: 0x81005007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vlsseg5e16_v,    mnemonic: "vlsseg5e16.v",    format: .vLoadStrided,   match: 0x88005007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssseg5e16_v,    mnemonic: "vssseg5e16.v",    format: .vStoreStrided,  match: 0x88005027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vluxseg5ei16_v,  mnemonic: "vluxseg5ei16.v",  format: .vLoadIndexed,   match: 0x84005007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vloxseg5ei16_v,  mnemonic: "vloxseg5ei16.v",  format: .vLoadIndexed,   match: 0x8C005007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsuxseg5ei16_v,  mnemonic: "vsuxseg5ei16.v",  format: .vStoreIndexed,  match: 0x84005027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vsoxseg5ei16_v,  mnemonic: "vsoxseg5ei16.v",  format: .vStoreIndexed,  match: 0x8C005027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vlseg5e32_v,     mnemonic: "vlseg5e32.v",     format: .vLoadUnit,      match: 0x80006007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsseg5e32_v,     mnemonic: "vsseg5e32.v",     format: .vStoreUnit,     match: 0x80006027, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vlseg5e32ff_v,   mnemonic: "vlseg5e32ff.v",   format: .vLoadUnit,      match: 0x81006007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vlsseg5e32_v,    mnemonic: "vlsseg5e32.v",    format: .vLoadStrided,   match: 0x88006007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssseg5e32_v,    mnemonic: "vssseg5e32.v",    format: .vStoreStrided,  match: 0x88006027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vluxseg5ei32_v,  mnemonic: "vluxseg5ei32.v",  format: .vLoadIndexed,   match: 0x84006007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vloxseg5ei32_v,  mnemonic: "vloxseg5ei32.v",  format: .vLoadIndexed,   match: 0x8C006007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsuxseg5ei32_v,  mnemonic: "vsuxseg5ei32.v",  format: .vStoreIndexed,  match: 0x84006027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vsoxseg5ei32_v,  mnemonic: "vsoxseg5ei32.v",  format: .vStoreIndexed,  match: 0x8C006027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vlseg5e64_v,     mnemonic: "vlseg5e64.v",     format: .vLoadUnit,      match: 0x80007007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsseg5e64_v,     mnemonic: "vsseg5e64.v",     format: .vStoreUnit,     match: 0x80007027, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vlseg5e64ff_v,   mnemonic: "vlseg5e64ff.v",   format: .vLoadUnit,      match: 0x81007007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vlsseg5e64_v,    mnemonic: "vlsseg5e64.v",    format: .vLoadStrided,   match: 0x88007007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssseg5e64_v,    mnemonic: "vssseg5e64.v",    format: .vStoreStrided,  match: 0x88007027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vluxseg5ei64_v,  mnemonic: "vluxseg5ei64.v",  format: .vLoadIndexed,   match: 0x84007007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vloxseg5ei64_v,  mnemonic: "vloxseg5ei64.v",  format: .vLoadIndexed,   match: 0x8C007007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsuxseg5ei64_v,  mnemonic: "vsuxseg5ei64.v",  format: .vStoreIndexed,  match: 0x84007027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vsoxseg5ei64_v,  mnemonic: "vsoxseg5ei64.v",  format: .vStoreIndexed,  match: 0x8C007027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vlseg6e8_v,      mnemonic: "vlseg6e8.v",      format: .vLoadUnit,      match: 0xA0000007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsseg6e8_v,      mnemonic: "vsseg6e8.v",      format: .vStoreUnit,     match: 0xA0000027, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vlseg6e8ff_v,    mnemonic: "vlseg6e8ff.v",    format: .vLoadUnit,      match: 0xA1000007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vlsseg6e8_v,     mnemonic: "vlsseg6e8.v",     format: .vLoadStrided,   match: 0xA8000007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssseg6e8_v,     mnemonic: "vssseg6e8.v",     format: .vStoreStrided,  match: 0xA8000027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vluxseg6ei8_v,   mnemonic: "vluxseg6ei8.v",   format: .vLoadIndexed,   match: 0xA4000007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vloxseg6ei8_v,   mnemonic: "vloxseg6ei8.v",   format: .vLoadIndexed,   match: 0xAC000007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsuxseg6ei8_v,   mnemonic: "vsuxseg6ei8.v",   format: .vStoreIndexed,  match: 0xA4000027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vsoxseg6ei8_v,   mnemonic: "vsoxseg6ei8.v",   format: .vStoreIndexed,  match: 0xAC000027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vlseg6e16_v,     mnemonic: "vlseg6e16.v",     format: .vLoadUnit,      match: 0xA0005007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsseg6e16_v,     mnemonic: "vsseg6e16.v",     format: .vStoreUnit,     match: 0xA0005027, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vlseg6e16ff_v,   mnemonic: "vlseg6e16ff.v",   format: .vLoadUnit,      match: 0xA1005007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vlsseg6e16_v,    mnemonic: "vlsseg6e16.v",    format: .vLoadStrided,   match: 0xA8005007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssseg6e16_v,    mnemonic: "vssseg6e16.v",    format: .vStoreStrided,  match: 0xA8005027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vluxseg6ei16_v,  mnemonic: "vluxseg6ei16.v",  format: .vLoadIndexed,   match: 0xA4005007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vloxseg6ei16_v,  mnemonic: "vloxseg6ei16.v",  format: .vLoadIndexed,   match: 0xAC005007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsuxseg6ei16_v,  mnemonic: "vsuxseg6ei16.v",  format: .vStoreIndexed,  match: 0xA4005027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vsoxseg6ei16_v,  mnemonic: "vsoxseg6ei16.v",  format: .vStoreIndexed,  match: 0xAC005027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vlseg6e32_v,     mnemonic: "vlseg6e32.v",     format: .vLoadUnit,      match: 0xA0006007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsseg6e32_v,     mnemonic: "vsseg6e32.v",     format: .vStoreUnit,     match: 0xA0006027, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vlseg6e32ff_v,   mnemonic: "vlseg6e32ff.v",   format: .vLoadUnit,      match: 0xA1006007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vlsseg6e32_v,    mnemonic: "vlsseg6e32.v",    format: .vLoadStrided,   match: 0xA8006007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssseg6e32_v,    mnemonic: "vssseg6e32.v",    format: .vStoreStrided,  match: 0xA8006027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vluxseg6ei32_v,  mnemonic: "vluxseg6ei32.v",  format: .vLoadIndexed,   match: 0xA4006007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vloxseg6ei32_v,  mnemonic: "vloxseg6ei32.v",  format: .vLoadIndexed,   match: 0xAC006007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsuxseg6ei32_v,  mnemonic: "vsuxseg6ei32.v",  format: .vStoreIndexed,  match: 0xA4006027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vsoxseg6ei32_v,  mnemonic: "vsoxseg6ei32.v",  format: .vStoreIndexed,  match: 0xAC006027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vlseg6e64_v,     mnemonic: "vlseg6e64.v",     format: .vLoadUnit,      match: 0xA0007007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsseg6e64_v,     mnemonic: "vsseg6e64.v",     format: .vStoreUnit,     match: 0xA0007027, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vlseg6e64ff_v,   mnemonic: "vlseg6e64ff.v",   format: .vLoadUnit,      match: 0xA1007007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vlsseg6e64_v,    mnemonic: "vlsseg6e64.v",    format: .vLoadStrided,   match: 0xA8007007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssseg6e64_v,    mnemonic: "vssseg6e64.v",    format: .vStoreStrided,  match: 0xA8007027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vluxseg6ei64_v,  mnemonic: "vluxseg6ei64.v",  format: .vLoadIndexed,   match: 0xA4007007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vloxseg6ei64_v,  mnemonic: "vloxseg6ei64.v",  format: .vLoadIndexed,   match: 0xAC007007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsuxseg6ei64_v,  mnemonic: "vsuxseg6ei64.v",  format: .vStoreIndexed,  match: 0xA4007027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vsoxseg6ei64_v,  mnemonic: "vsoxseg6ei64.v",  format: .vStoreIndexed,  match: 0xAC007027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vlseg7e8_v,      mnemonic: "vlseg7e8.v",      format: .vLoadUnit,      match: 0xC0000007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsseg7e8_v,      mnemonic: "vsseg7e8.v",      format: .vStoreUnit,     match: 0xC0000027, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vlseg7e8ff_v,    mnemonic: "vlseg7e8ff.v",    format: .vLoadUnit,      match: 0xC1000007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vlsseg7e8_v,     mnemonic: "vlsseg7e8.v",     format: .vLoadStrided,   match: 0xC8000007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssseg7e8_v,     mnemonic: "vssseg7e8.v",     format: .vStoreStrided,  match: 0xC8000027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vluxseg7ei8_v,   mnemonic: "vluxseg7ei8.v",   format: .vLoadIndexed,   match: 0xC4000007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vloxseg7ei8_v,   mnemonic: "vloxseg7ei8.v",   format: .vLoadIndexed,   match: 0xCC000007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsuxseg7ei8_v,   mnemonic: "vsuxseg7ei8.v",   format: .vStoreIndexed,  match: 0xC4000027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vsoxseg7ei8_v,   mnemonic: "vsoxseg7ei8.v",   format: .vStoreIndexed,  match: 0xCC000027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vlseg7e16_v,     mnemonic: "vlseg7e16.v",     format: .vLoadUnit,      match: 0xC0005007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsseg7e16_v,     mnemonic: "vsseg7e16.v",     format: .vStoreUnit,     match: 0xC0005027, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vlseg7e16ff_v,   mnemonic: "vlseg7e16ff.v",   format: .vLoadUnit,      match: 0xC1005007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vlsseg7e16_v,    mnemonic: "vlsseg7e16.v",    format: .vLoadStrided,   match: 0xC8005007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssseg7e16_v,    mnemonic: "vssseg7e16.v",    format: .vStoreStrided,  match: 0xC8005027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vluxseg7ei16_v,  mnemonic: "vluxseg7ei16.v",  format: .vLoadIndexed,   match: 0xC4005007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vloxseg7ei16_v,  mnemonic: "vloxseg7ei16.v",  format: .vLoadIndexed,   match: 0xCC005007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsuxseg7ei16_v,  mnemonic: "vsuxseg7ei16.v",  format: .vStoreIndexed,  match: 0xC4005027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vsoxseg7ei16_v,  mnemonic: "vsoxseg7ei16.v",  format: .vStoreIndexed,  match: 0xCC005027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vlseg7e32_v,     mnemonic: "vlseg7e32.v",     format: .vLoadUnit,      match: 0xC0006007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsseg7e32_v,     mnemonic: "vsseg7e32.v",     format: .vStoreUnit,     match: 0xC0006027, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vlseg7e32ff_v,   mnemonic: "vlseg7e32ff.v",   format: .vLoadUnit,      match: 0xC1006007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vlsseg7e32_v,    mnemonic: "vlsseg7e32.v",    format: .vLoadStrided,   match: 0xC8006007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssseg7e32_v,    mnemonic: "vssseg7e32.v",    format: .vStoreStrided,  match: 0xC8006027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vluxseg7ei32_v,  mnemonic: "vluxseg7ei32.v",  format: .vLoadIndexed,   match: 0xC4006007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vloxseg7ei32_v,  mnemonic: "vloxseg7ei32.v",  format: .vLoadIndexed,   match: 0xCC006007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsuxseg7ei32_v,  mnemonic: "vsuxseg7ei32.v",  format: .vStoreIndexed,  match: 0xC4006027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vsoxseg7ei32_v,  mnemonic: "vsoxseg7ei32.v",  format: .vStoreIndexed,  match: 0xCC006027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vlseg7e64_v,     mnemonic: "vlseg7e64.v",     format: .vLoadUnit,      match: 0xC0007007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsseg7e64_v,     mnemonic: "vsseg7e64.v",     format: .vStoreUnit,     match: 0xC0007027, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vlseg7e64ff_v,   mnemonic: "vlseg7e64ff.v",   format: .vLoadUnit,      match: 0xC1007007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vlsseg7e64_v,    mnemonic: "vlsseg7e64.v",    format: .vLoadStrided,   match: 0xC8007007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssseg7e64_v,    mnemonic: "vssseg7e64.v",    format: .vStoreStrided,  match: 0xC8007027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vluxseg7ei64_v,  mnemonic: "vluxseg7ei64.v",  format: .vLoadIndexed,   match: 0xC4007007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vloxseg7ei64_v,  mnemonic: "vloxseg7ei64.v",  format: .vLoadIndexed,   match: 0xCC007007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsuxseg7ei64_v,  mnemonic: "vsuxseg7ei64.v",  format: .vStoreIndexed,  match: 0xC4007027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vsoxseg7ei64_v,  mnemonic: "vsoxseg7ei64.v",  format: .vStoreIndexed,  match: 0xCC007027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vlseg8e8_v,      mnemonic: "vlseg8e8.v",      format: .vLoadUnit,      match: 0xE0000007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsseg8e8_v,      mnemonic: "vsseg8e8.v",      format: .vStoreUnit,     match: 0xE0000027, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vlseg8e8ff_v,    mnemonic: "vlseg8e8ff.v",    format: .vLoadUnit,      match: 0xE1000007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vlsseg8e8_v,     mnemonic: "vlsseg8e8.v",     format: .vLoadStrided,   match: 0xE8000007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssseg8e8_v,     mnemonic: "vssseg8e8.v",     format: .vStoreStrided,  match: 0xE8000027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vluxseg8ei8_v,   mnemonic: "vluxseg8ei8.v",   format: .vLoadIndexed,   match: 0xE4000007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vloxseg8ei8_v,   mnemonic: "vloxseg8ei8.v",   format: .vLoadIndexed,   match: 0xEC000007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsuxseg8ei8_v,   mnemonic: "vsuxseg8ei8.v",   format: .vStoreIndexed,  match: 0xE4000027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vsoxseg8ei8_v,   mnemonic: "vsoxseg8ei8.v",   format: .vStoreIndexed,  match: 0xEC000027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vlseg8e16_v,     mnemonic: "vlseg8e16.v",     format: .vLoadUnit,      match: 0xE0005007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsseg8e16_v,     mnemonic: "vsseg8e16.v",     format: .vStoreUnit,     match: 0xE0005027, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vlseg8e16ff_v,   mnemonic: "vlseg8e16ff.v",   format: .vLoadUnit,      match: 0xE1005007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vlsseg8e16_v,    mnemonic: "vlsseg8e16.v",    format: .vLoadStrided,   match: 0xE8005007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssseg8e16_v,    mnemonic: "vssseg8e16.v",    format: .vStoreStrided,  match: 0xE8005027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vluxseg8ei16_v,  mnemonic: "vluxseg8ei16.v",  format: .vLoadIndexed,   match: 0xE4005007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vloxseg8ei16_v,  mnemonic: "vloxseg8ei16.v",  format: .vLoadIndexed,   match: 0xEC005007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsuxseg8ei16_v,  mnemonic: "vsuxseg8ei16.v",  format: .vStoreIndexed,  match: 0xE4005027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vsoxseg8ei16_v,  mnemonic: "vsoxseg8ei16.v",  format: .vStoreIndexed,  match: 0xEC005027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vlseg8e32_v,     mnemonic: "vlseg8e32.v",     format: .vLoadUnit,      match: 0xE0006007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsseg8e32_v,     mnemonic: "vsseg8e32.v",     format: .vStoreUnit,     match: 0xE0006027, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vlseg8e32ff_v,   mnemonic: "vlseg8e32ff.v",   format: .vLoadUnit,      match: 0xE1006007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vlsseg8e32_v,    mnemonic: "vlsseg8e32.v",    format: .vLoadStrided,   match: 0xE8006007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssseg8e32_v,    mnemonic: "vssseg8e32.v",    format: .vStoreStrided,  match: 0xE8006027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vluxseg8ei32_v,  mnemonic: "vluxseg8ei32.v",  format: .vLoadIndexed,   match: 0xE4006007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vloxseg8ei32_v,  mnemonic: "vloxseg8ei32.v",  format: .vLoadIndexed,   match: 0xEC006007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsuxseg8ei32_v,  mnemonic: "vsuxseg8ei32.v",  format: .vStoreIndexed,  match: 0xE4006027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vsoxseg8ei32_v,  mnemonic: "vsoxseg8ei32.v",  format: .vStoreIndexed,  match: 0xEC006027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vlseg8e64_v,     mnemonic: "vlseg8e64.v",     format: .vLoadUnit,      match: 0xE0007007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsseg8e64_v,     mnemonic: "vsseg8e64.v",     format: .vStoreUnit,     match: 0xE0007027, mask: 0xFDF0707F),
        RV64InstrDesc(opcode: .vlseg8e64ff_v,   mnemonic: "vlseg8e64ff.v",   format: .vLoadUnit,      match: 0xE1007007, mask: 0xFDF0707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vlsseg8e64_v,    mnemonic: "vlsseg8e64.v",    format: .vLoadStrided,   match: 0xE8007007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vssseg8e64_v,    mnemonic: "vssseg8e64.v",    format: .vStoreStrided,  match: 0xE8007027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vluxseg8ei64_v,  mnemonic: "vluxseg8ei64.v",  format: .vLoadIndexed,   match: 0xE4007007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vloxseg8ei64_v,  mnemonic: "vloxseg8ei64.v",  format: .vLoadIndexed,   match: 0xEC007007, mask: 0xFC00707F, flags: [.vdNotMask]),
        RV64InstrDesc(opcode: .vsuxseg8ei64_v,  mnemonic: "vsuxseg8ei64.v",  format: .vStoreIndexed,  match: 0xE4007027, mask: 0xFC00707F),
        RV64InstrDesc(opcode: .vsoxseg8ei64_v,  mnemonic: "vsoxseg8ei64.v",  format: .vStoreIndexed,  match: 0xEC007027, mask: 0xFC00707F),
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

        case .cAddi, .cNop:
            let b12 = UInt16((imm >> 5) & 0x1) << 12
            let b6_2 = UInt16(imm & 0x1F) << 2
            hw |= b12 | (rd << 7) | b6_2
            hw &= ~UInt16(truncatingIfNeeded: desc.mask) | UInt16(truncatingIfNeeded: desc.match) // c.nop: rd stays x0

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
    ///
    /// Operand fields are placed according to the descriptor's format, then every bit the descriptor fixes
    /// (`mask`) is taken from `match`, so an operand can never corrupt a fixed field (the `vs1` selector of
    /// `vzext.vf2`, the `vm` bit of `vmv.v.v`, the `nf` field of `vlseg4e32.v`, ...).
    public static func encode32(_ inst: RV64Instruction) -> UInt32 {
        let desc = RV64InstructionTable.descriptor(for: inst.opcode)
        let rd = UInt32(inst.rd & 0x1F) << 7
        let rs1 = UInt32(inst.rs1 & 0x1F) << 15
        let rs2 = UInt32(inst.rs2 & 0x1F) << 20
        let rm = UInt32(inst.rm.rawValue & 0x7) << 12
        let vm: UInt32 = inst.vm ? (1 << 25) : 0
        let imm = inst.imm
        let uimm = UInt32(bitPattern: Int32(truncatingIfNeeded: imm))
        let imm5 = (uimm & 0x1F) << 15

        let fields: UInt32
        switch desc.format {
        case .r, .rFPFixed, .rFPCmp, .vsetvl:
            fields = rs2 | rs1 | rd

        case .rUnary, .rFPMvF2I, .rFPMvI2F, .rFPCvtMod, .hlv, .vLoadWhole, .vStoreWhole:
            fields = rs1 | rd

        case .rShift64:
            fields = ((uimm & 0x3F) << 20) | rs1 | rd

        case .rShift32:
            fields = ((uimm & 0x1F) << 20) | rs1 | rd

        case .rAMO, .rLR:
            let aqBit: UInt32 = inst.aq ? (1 << 26) : 0
            let rlBit: UInt32 = inst.rl ? (1 << 25) : 0
            fields = aqBit | rlBit | rs2 | rs1 | rd

        case .rFP:
            fields = rs2 | rs1 | rm | rd

        case .rFMA:
            fields = (UInt32(inst.rs3 & 0x1F) << 27) | rs2 | rs1 | rm | rd

        case .rFPUnary, .rFPCvtF2I, .rFPCvtI2F:
            fields = rs1 | rm | rd

        case .rFLI:
            fields = imm5 | rd

        case .i, .iLoad, .iFPLoad:
            fields = ((uimm & 0xFFF) << 20) | rs1 | rd

        case .s, .sFP:
            fields = (((uimm >> 5) & 0x7F) << 25) | rs2 | rs1 | ((uimm & 0x1F) << 7)

        case .b:
            let b12 = (uimm >> 12) & 0x1
            let b11 = (uimm >> 11) & 0x1
            let b10_5 = (uimm >> 5) & 0x3F
            let b4_1 = (uimm >> 1) & 0xF
            fields = (b12 << 31) | (b10_5 << 25) | rs2 | rs1 | (b4_1 << 8) | (b11 << 7)

        case .u:
            // `imm` is the 20-bit upper immediate, or a full value with zero low 12 bits (`lui rd, 0x12345000`).
            let u20: UInt32
            if (imm & 0xFFF) == 0 && (imm > 0xFFFFF || imm < -0x80000) {
                u20 = UInt32(bitPattern: Int32(truncatingIfNeeded: imm >> 12)) & 0xFFFFF
            } else {
                u20 = uimm & 0xFFFFF
            }
            fields = (u20 << 12) | rd

        case .j:
            let b20 = (uimm >> 20) & 0x1
            let b19_12 = (uimm >> 12) & 0xFF
            let b11 = (uimm >> 11) & 0x1
            let b10_1 = (uimm >> 1) & 0x3FF
            fields = (b20 << 31) | (b10_1 << 21) | (b11 << 20) | (b19_12 << 12) | rd

        case .fence:
            // imm = pred << 4 | succ (`fence iorw, iorw` = 0xFF).
            fields = (uimm & 0xFF) << 20

        case .csrReg, .csrImm:
            // csrImm keeps its 5-bit zero-extended immediate in `rs1`.
            fields = ((uimm & 0xFFF) << 20) | rs1 | rd

        case .systemFixed:
            fields = 0

        case .sfenceVMA, .hsv:
            fields = rs2 | rs1

        case .cbo:
            fields = rs1

        case .prefetch:
            fields = (((uimm >> 5) & 0x7F) << 25) | rs1

        case .vsetvli:
            fields = ((uimm & 0x7FF) << 20) | rs1 | rd

        case .vsetivli:
            // The AVL immediate (uimm5) is kept in `rs1`, the vtypei in `imm`.
            fields = ((uimm & 0x3FF) << 20) | rs1 | rd

        case .vLoadUnit, .vStoreUnit:
            fields = vm | rs1 | rd

        case .vLoadStrided, .vStoreStrided, .vLoadIndexed, .vStoreIndexed,
             .vVV, .vVX, .vVF, .vMAccVV, .vMAccVX, .vMAccVF:
            fields = vm | rs2 | rs1 | rd

        case .vVI, .vVUI:
            fields = vm | rs2 | imm5 | rd

        case .vVUI6:
            fields = (((uimm >> 5) & 0x1) << 26) | vm | rs2 | imm5 | rd

        case .vUnary, .vToX, .vToF:
            fields = vm | rs2 | rd

        case .vNullary:
            fields = vm | rd

        case .vMvVV, .vMvVX, .vMvVF:
            fields = rs1 | rd

        case .vMvVI:
            fields = imm5 | rd

        case .cFixed, .cNop, .cAddi, .cAddi16sp, .cAddi4spn, .cLui, .cShift, .cAndi, .cAlu, .cZcbUnary, .cSlli, .cCR, .cJr,
             .cLw, .cLd, .cFld, .cSw, .cSd, .cFsd, .cLwsp, .cLdsp, .cFldsp, .cSwsp, .cSdsp, .cFsdsp, .cJ, .cBranch,
             .cZcbByte, .cZcbHalf:
            fields = 0 // 16-bit formats are encoded by `encode16`
        }

        return desc.match | (fields & ~desc.mask)
    }

    // MARK: - 3.0 Operand Validation (`validate`)

    /// Checks the operand rules an encoding cannot express by itself: immediate ranges and alignment,
    /// RVC register and immediate restrictions (reserved/HINT forms), and the RVV register-overlap and
    /// register-group rules (`RV64DescFlags`). Returns `nil` if `inst` is valid, else a diagnostic message.
    /// The vector rules match LLVM MC's, which compares register numbers exactly (no `LMUL`-group overlap).
    public static func validate(_ inst: RV64Instruction) -> String? {
        let desc = RV64InstructionTable.descriptor(for: inst.opcode)
        let flags = desc.flags
        let imm = inst.imm

        func inRange(_ lo: Int64, _ hi: Int64, multipleOf m: Int64 = 1) -> Bool {
            imm >= lo && imm <= hi && imm % m == 0
        }

        if inst.rd > 31 || inst.rs1 > 31 || inst.rs2 > 31 || inst.rs3 > 31 {
            return "register index out of range"
        }

        // Immediate ranges
        let immOK: Bool
        switch desc.format {
        case .i, .iLoad, .iFPLoad, .s, .sFP: immOK = inRange(-2048, 2047)
        case .b: immOK = inRange(-4096, 4094, multipleOf: 2)
        case .j: immOK = inRange(-(1 << 20), (1 << 20) - 2, multipleOf: 2)
        case .u: immOK = inRange(0, 0xFFFFF) || ((imm & 0xFFF) == 0 && inRange(-(1 << 31), (1 << 32) - 1))
        case .rShift64: immOK = inRange(0, 63)
        case .rShift32, .rFLI: immOK = inRange(0, 31)
        case .fence: immOK = inRange(0, 0xFF)
        case .csrReg, .csrImm: immOK = inRange(0, 0xFFF)
        case .prefetch: immOK = inRange(-2048, 2016, multipleOf: 32)
        case .vsetvli: immOK = inRange(0, 0x7FF)
        case .vsetivli: immOK = inRange(0, 0x3FF)
        case .vVI, .vMvVI: immOK = inRange(-16, 15)
        case .vVUI: immOK = inRange(0, 31)
        case .vVUI6: immOK = inRange(0, 63)
        case .cAddi, .cAndi, .cNop: immOK = inRange(-32, 31)
        case .cLui: immOK = inRange(-32, 31) && imm != 0
        case .cShift, .cSlli: immOK = inRange(0, 63)
        case .cAddi16sp: immOK = inRange(-512, 496, multipleOf: 16) && imm != 0
        case .cAddi4spn: immOK = inRange(4, 1020, multipleOf: 4)
        case .cLw, .cSw: immOK = inRange(0, 124, multipleOf: 4)
        case .cLd, .cSd, .cFld, .cFsd: immOK = inRange(0, 248, multipleOf: 8)
        case .cLwsp, .cSwsp: immOK = inRange(0, 252, multipleOf: 4)
        case .cLdsp, .cSdsp, .cFldsp, .cFsdsp: immOK = inRange(0, 504, multipleOf: 8)
        case .cJ: immOK = inRange(-2048, 2046, multipleOf: 2)
        case .cBranch: immOK = inRange(-256, 254, multipleOf: 2)
        case .cZcbByte: immOK = inRange(0, 3)
        case .cZcbHalf: immOK = inRange(0, 2, multipleOf: 2)
        default: immOK = true
        }
        if !immOK {
            return "immediate \(imm) out of range for \(desc.mnemonic)"
        }
        if (desc.format == .csrImm || desc.format == .vsetivli) && inst.rs1 > 31 {
            return "immediate out of range for \(desc.mnemonic)"
        }

        // RVC register restrictions: compressed-register fields, and the reserved encodings (and those that are
        // another instruction's: c.addi x0 is c.nop, c.lui sp is c.addi16sp, c.mv/c.add x0 rs2 is c.jr/c.jalr/
        // c.ebreak). HINT forms (c.nop imm, c.addi rd 0, c.li/c.lui/c.slli/c.mv/c.add with rd = x0, shamt 0) are valid.
        if desc.isCompressed {
            func prime(_ r: UInt8) -> Bool { r >= 8 && r <= 15 }
            switch desc.format {
            case .cAddi:
                if inst.rd == 0 && inst.opcode != .c_li { return "\(desc.mnemonic) requires rd != x0" }
                if inst.opcode != .c_li && inst.rs1 != inst.rd { return "\(desc.mnemonic) requires rd == rs1" }
            case .cLui:
                if inst.rd == 2 { return "c.lui requires rd != x2" }
            case .cSlli:
                if inst.rs1 != inst.rd { return "c.slli requires rd == rs1" }
            case .cCR:
                if inst.rs2 == 0 { return "\(desc.mnemonic) requires rs2 != x0" }
                if inst.opcode == .c_add && inst.rs1 != inst.rd { return "c.add requires rd == rs1" }
            case .cJr:
                if inst.rs1 == 0 { return "\(desc.mnemonic) requires rs1 != x0" }
            case .cLwsp, .cLdsp:
                if inst.rd == 0 { return "\(desc.mnemonic) requires rd != x0" }
            case .cShift, .cAndi, .cAlu, .cZcbUnary:
                if !prime(inst.rd) || inst.rs1 != inst.rd { return "\(desc.mnemonic) requires rd == rs1 in x8..x15" }
                if desc.format == .cAlu && !prime(inst.rs2) { return "\(desc.mnemonic) requires rs2 in x8..x15" }
            case .cAddi4spn:
                if !prime(inst.rd) { return "c.addi4spn requires rd in x8..x15" }
            case .cLw, .cLd, .cFld, .cZcbByte, .cZcbHalf, .cSw, .cSd, .cFsd, .cBranch:
                let isStore = desc.format == .cSw || desc.format == .cSd || desc.format == .cFsd
                    || inst.opcode == .c_sb || inst.opcode == .c_sh
                let data = isStore ? inst.rs2 : inst.rd
                if !prime(inst.rs1) || (desc.format != .cBranch && !prime(data)) {
                    return "\(desc.mnemonic) requires registers in x8..x15"
                }
            default:
                break
            }
            return nil
        }

        // RVV register-group alignment and overlap rules
        let group = flags.registerGroup
        if group > 1 {
            if inst.rd % group != 0 || (desc.format == .vUnary && inst.rs2 % group != 0) {
                return "\(desc.mnemonic) requires registers aligned to a group of \(group)"
            }
        }
        if flags.contains(.vdNotMask) && inst.rd == 0 && (desc.readsV0Implicitly || (desc.isMaskable && !inst.vm)) {
            return "the destination vector register group cannot overlap the mask register"
        }
        if flags.contains(.vdNotVs2) && inst.rd == inst.rs2 {
            return "the destination vector register group cannot overlap the source vector register group"
        }
        if flags.contains(.vdNotVs1) && inst.rd == inst.rs1
            && (desc.format == .vVV || desc.format == .vMAccVV) {
            return "the destination vector register group cannot overlap the source vector register group"
        }
        return nil
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
            // c.li: addiw rd, x0, imm (rd != x0, imm in -32..31) loads the same sign-extended value as addi.
            if rs1 == .zero && rd != .zero && imm >= -32 && imm <= 31 {
                return RV64Instruction(opcode: .c_li, rd: rd.rawValue, imm: imm)
            }
            // c.addiw: addiw rd, rd, imm (rd != x0, imm in -32..31; imm 0 is `sext.w`)
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
    public static func expandLi(rd: RVGPR, imm: Int64, rvcEnabled: Bool = true, zbsEnabled: Bool = true) -> [RV64Instruction] {
        // `li zero, imm` materializes into x0 like any register (LLVM MC: `li zero, 5` is `addi zero, zero, 5`).
        let rawSeq = synthesizeLi64(rd: rd, val: imm, zbs: zbsEnabled)
        if !rvcEnabled {
            return rawSeq
        }
        return rawSeq.map { compressInstruction($0) ?? $0 }
    }

    private static func synthesizeLi64(rd: RVGPR, val: Int64, zbs: Bool) -> [RV64Instruction] {
        // 1. Fits in signed 12-bit immediate (-2048..2047)
        if val >= -2048 && val <= 2047 {
            return [.gpr(.addi, rd: rd, rs1: .zero, imm: val)]
        }

        let uval = UInt64(bitPattern: val)
        let tz = uval.trailingZeroBitCount

        // 2. Single-bit power-of-two in upper 33 bits (bit 31..63): single Zbs `bseti rd, zero, shamt` (without Zbs,
        //    e.g. VectraOS's rv64imac kernel, `li t0, 8 << 60` is `c.li t0, -1; c.slli t0, 63`)
        if zbs && uval.nonzeroBitCount == 1 && tz >= 31 {
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
            let signedCandidate = synthesizeLiNoTrailingShift(rd: rd, val: shiftedSigned, zbs: zbs) + [
                .gpr(.slli, rd: rd, rs1: rd, imm: Int64(tz))
            ]

            let shiftedUnsigned = Int64(bitPattern: uval >> tz)
            if shiftedUnsigned != shiftedSigned && shiftedUnsigned > 0 {
                let unsignedCandidate = synthesizeLiNoTrailingShift(rd: rd, val: shiftedUnsigned, zbs: zbs) + [
                    .gpr(.slli, rd: rd, rs1: rd, imm: Int64(tz))
                ]
                if unsignedCandidate.count < signedCandidate.count {
                    let directCandidate = synthesizeLiNoTrailingShift(rd: rd, val: val, zbs: zbs)
                    return unsignedCandidate.count <= directCandidate.count ? unsignedCandidate : directCandidate
                }
            }

            let directCandidate = synthesizeLiNoTrailingShift(rd: rd, val: val, zbs: zbs)
            if signedCandidate.count <= directCandidate.count {
                return signedCandidate
            }
            return directCandidate
        }

        return synthesizeLiNoTrailingShift(rd: rd, val: val, zbs: zbs)
    }

    private static func synthesizeLiNoTrailingShift(rd: RVGPR, val: Int64, zbs: Bool) -> [RV64Instruction] {
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

        var seq = synthesizeLi64(rd: rd, val: hi, zbs: zbs)
        seq.append(.gpr(.slli, rd: rd, rs1: rd, imm: Int64(shift)))
        if lo12 != 0 {
            seq.append(.gpr(.addi, rd: rd, rs1: rd, imm: lo12))
        }
        return seq
    }
}

// MARK: - 5. RV64 Disassembler & Round-Trip Verification

public enum RV64Disassembler {
    /// Orders candidate descriptors most specific (most fixed bits) first, so aliases that fix more bits win
    /// (`c.unimp`, `c.nop`, `c.ebreak`, `c.mop.N`, `c.ntl.*` before `c.addi`/`c.lui`/`c.add`; `pause` before
    /// `fence`; `prefetch.*` before `ori`; `ntl.*` before `add`; `vmv.v.v` before `vmerge.vvm`).
    private static func bySpecificity(_ a: RV64InstrDesc, _ b: RV64InstrDesc) -> Bool {
        let ca = a.mask.nonzeroBitCount
        let cb = b.mask.nonzeroBitCount
        if ca != cb { return ca > cb }
        return a.opcode.rawValue < b.opcode.rawValue
    }

    /// Compressed descriptors bucketed by quadrant and `funct3` (`(hw & 3) << 3 | hw >> 13`), each bucket
    /// sorted by specificity. Every RVC/Zcb/Zcmop descriptor fixes both fields.
    private static let compressedDecodeBuckets: [[RV64InstrDesc]] = {
        var buckets = [[RV64InstrDesc]](repeating: [], count: 32)
        for desc in RV64InstructionTable.descriptors where desc.isCompressed {
            precondition((desc.mask & 0xE003) == 0xE003, "\(desc.mnemonic): RVC descriptor must fix quadrant and funct3")
            buckets[Int(((desc.match & 3) << 3) | ((desc.match >> 13) & 7))].append(desc)
        }
        return buckets.map { $0.sorted(by: bySpecificity) }
    }()

    /// Standard 32-bit descriptors bucketed by major opcode (bits [6:2]), each bucket sorted by specificity.
    private static let standardDecodeBuckets: [[RV64InstrDesc]] = {
        var buckets = [[RV64InstrDesc]](repeating: [], count: 32)
        for desc in RV64InstructionTable.descriptors where !desc.isCompressed {
            precondition((desc.mask & 0x7F) == 0x7F, "\(desc.mnemonic): descriptor must fix the major opcode")
            buckets[Int((desc.match >> 2) & 0x1F)].append(desc)
        }
        return buckets.map { $0.sorted(by: bySpecificity) }
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
        for desc in compressedDecodeBuckets[Int(((hw & 3) << 3) | (hw >> 13))] {
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
                // rd = x0 is a HINT; rd = x2 is c.addi16sp
                let rd = (hw >> 7) & 0x1F
                let imm = extractCIImm(hw)
                if rd == 2 || imm == 0 { continue }
            case .c_jr, .c_jalr:
                let rs1 = (hw >> 7) & 0x1F
                if rs1 == 0 { continue }
            case .c_mv, .c_add:
                // rd = x0 is a HINT; rs2 = x0 is c.jr / c.jalr / c.ebreak
                let rs2 = (hw >> 2) & 0x1F
                if rs2 == 0 { continue }
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

        case .cNop:
            return RV64Instruction(opcode: desc.opcode, imm: extractCIImm(hw))

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

    /// Decodes a 32-bit standard instruction word, or returns `nil` if no descriptor matches
    /// (or a rounding-mode field holds a reserved value, `0b101`/`0b110`).
    public static func decode32(_ word: UInt32) -> RV64Instruction? {
        for desc in standardDecodeBuckets[Int((word >> 2) & 0x1F)] {
            guard (word & desc.mask) == desc.match else { continue }
            return decodeStandardFields(word, desc: desc)
        }
        return nil
    }

    private static func decodeStandardFields(_ word: UInt32, desc: RV64InstrDesc) -> RV64Instruction? {
        let rd = UInt8((word >> 7) & 0x1F)
        let rs1 = UInt8((word >> 15) & 0x1F)
        let rs2 = UInt8((word >> 20) & 0x1F)
        let vm = ((word >> 25) & 0x1) != 0
        let op = desc.opcode
        let simm5 = (Int64(rs1) << 59) >> 59

        var rm: RVRoundingMode = .dyn
        switch desc.format {
        case .rFP, .rFMA, .rFPUnary, .rFPCvtF2I, .rFPCvtI2F:
            guard let mode = RVRoundingMode(rawValue: UInt8((word >> 12) & 0x7)) else { return nil }
            rm = mode
        default:
            break
        }

        switch desc.format {
        case .r, .rFPFixed, .rFPCmp, .vsetvl:
            return RV64Instruction(opcode: op, rd: rd, rs1: rs1, rs2: rs2)

        case .rUnary, .rFPMvF2I, .rFPMvI2F, .hlv:
            return RV64Instruction(opcode: op, rd: rd, rs1: rs1)

        case .rFPCvtMod:
            return RV64Instruction(opcode: op, rd: rd, rs1: rs1, rm: .rtz)

        case .rShift64:
            return RV64Instruction(opcode: op, rd: rd, rs1: rs1, imm: Int64((word >> 20) & 0x3F))

        case .rShift32:
            return RV64Instruction(opcode: op, rd: rd, rs1: rs1, imm: Int64((word >> 20) & 0x1F))

        case .rAMO, .rLR:
            let aq = ((word >> 26) & 0x1) != 0
            let rl = ((word >> 25) & 0x1) != 0
            return RV64Instruction(opcode: op, rd: rd, rs1: rs1, rs2: desc.format == .rAMO ? rs2 : 0, aq: aq, rl: rl)

        case .rFP:
            return RV64Instruction(opcode: op, rd: rd, rs1: rs1, rs2: rs2, rm: rm)

        case .rFMA:
            return RV64Instruction(opcode: op, rd: rd, rs1: rs1, rs2: rs2, rs3: UInt8(word >> 27), rm: rm)

        case .rFPUnary, .rFPCvtF2I, .rFPCvtI2F:
            return RV64Instruction(opcode: op, rd: rd, rs1: rs1, rm: rm)

        case .rFLI:
            return RV64Instruction(opcode: op, rd: rd, imm: Int64(rs1))

        case .i, .iLoad, .iFPLoad:
            let imm12 = (Int64(word >> 20) << 52) >> 52
            return RV64Instruction(opcode: op, rd: rd, rs1: rs1, imm: imm12)

        case .s, .sFP:
            let u12 = (Int64((word >> 25) & 0x7F) << 5) | Int64((word >> 7) & 0x1F)
            return RV64Instruction(opcode: op, rs1: rs1, rs2: rs2, imm: (u12 << 52) >> 52)

        case .b:
            let b12 = Int64((word >> 31) & 0x1) << 12
            let b11 = Int64((word >> 7) & 0x1) << 11
            let b10_5 = Int64((word >> 25) & 0x3F) << 5
            let b4_1 = Int64((word >> 8) & 0xF) << 1
            let u13 = b12 | b11 | b10_5 | b4_1
            return RV64Instruction(opcode: op, rs1: rs1, rs2: rs2, imm: (u13 << 51) >> 51)

        case .u:
            return RV64Instruction(opcode: op, rd: rd, imm: Int64((word >> 12) & 0xFFFFF))

        case .j:
            let b20 = Int64((word >> 31) & 0x1) << 20
            let b19_12 = Int64((word >> 12) & 0xFF) << 12
            let b11 = Int64((word >> 20) & 0x1) << 11
            let b10_1 = Int64((word >> 21) & 0x3FF) << 1
            let u21 = b20 | b19_12 | b11 | b10_1
            return RV64Instruction(opcode: op, rd: rd, imm: (u21 << 43) >> 43)

        case .fence:
            return RV64Instruction(opcode: op, imm: Int64((word >> 20) & 0xFF))

        case .csrReg, .csrImm:
            return RV64Instruction(opcode: op, rd: rd, rs1: rs1, imm: Int64((word >> 20) & 0xFFF))

        case .systemFixed:
            return RV64Instruction(opcode: op)

        case .sfenceVMA, .hsv:
            return RV64Instruction(opcode: op, rs1: rs1, rs2: rs2)

        case .cbo:
            return RV64Instruction(opcode: op, rs1: rs1)

        case .prefetch:
            let imm7 = (Int64(word >> 25) << 57) >> 57
            return RV64Instruction(opcode: op, rs1: rs1, imm: imm7 << 5)

        case .vsetvli:
            return RV64Instruction(opcode: op, rd: rd, rs1: rs1, imm: Int64((word >> 20) & 0x7FF))

        case .vsetivli:
            return RV64Instruction(opcode: op, rd: rd, rs1: rs1, imm: Int64((word >> 20) & 0x3FF))

        case .vLoadUnit, .vStoreUnit, .vLoadWhole, .vStoreWhole:
            return RV64Instruction(opcode: op, rd: rd, rs1: rs1, vm: vm)

        case .vLoadStrided, .vStoreStrided, .vLoadIndexed, .vStoreIndexed,
             .vVV, .vVX, .vVF, .vMAccVV, .vMAccVX, .vMAccVF:
            return RV64Instruction(opcode: op, rd: rd, rs1: rs1, rs2: rs2, vm: vm)

        case .vVI:
            return RV64Instruction(opcode: op, rd: rd, rs2: rs2, imm: simm5, vm: vm)

        case .vVUI:
            return RV64Instruction(opcode: op, rd: rd, rs2: rs2, imm: Int64(rs1), vm: vm)

        case .vVUI6:
            return RV64Instruction(opcode: op, rd: rd, rs2: rs2, imm: Int64(rs1) | (Int64((word >> 26) & 0x1) << 5), vm: vm)

        case .vUnary, .vToX, .vToF:
            return RV64Instruction(opcode: op, rd: rd, rs2: rs2, vm: vm)

        case .vNullary:
            return RV64Instruction(opcode: op, rd: rd, vm: vm)

        case .vMvVV, .vMvVX, .vMvVF:
            return RV64Instruction(opcode: op, rd: rd, rs1: rs1, vm: vm)

        case .vMvVI:
            return RV64Instruction(opcode: op, rd: rd, imm: simm5, vm: vm)

        case .cFixed, .cNop, .cAddi, .cAddi16sp, .cAddi4spn, .cLui, .cShift, .cAndi, .cAlu, .cZcbUnary, .cSlli, .cCR, .cJr,
             .cLw, .cLd, .cFld, .cSw, .cSd, .cFsd, .cLwsp, .cLdsp, .cFldsp, .cSwsp, .cSdsp, .cFsdsp, .cJ, .cBranch,
             .cZcbByte, .cZcbHalf:
            return nil // 16-bit formats are decoded by `decode16`
        }
    }

    /// Formats an `RV64Instruction` as `llvm-objdump` prints it (`aliases`, the default): a compressed instruction
    /// as the 32-bit instruction it expands to, then LLVM MC's preferred alias (`li`, `mv`, `ret`, `csrr`, `beqz`,
    /// `fmv.s`, `vl1r.v`, `vmclr.m`, ...). With `aliases: false`, the canonical form under the instruction's own
    /// mnemonic (`c.addi a0, 1`, `addi a0, zero, 1`). Both assemble back to the same encoding with LLVM MC (the
    /// alias text of a compressed instruction only when C is enabled).
    public static func format(_ inst: RV64Instruction, aliases: Bool = true) -> String {
        if aliases {
            if inst.isCompressed {
                if inst.opcode == .c_unimp { return "unimp" }
                if let wide = uncompress(inst) { return format(wide) }
            } else if let text = preferredAlias(inst) {
                return text
            }
        }
        return canonicalText(inst)
    }

    /// The 32-bit instruction a compressed one expands to, as LLVM's `RISCVRVC::uncompress`; `nil` for the HINT
    /// encodings (`c.nop imm`, `c.addi rd, 0`, `c.li`/`c.lui`/`c.mv`/`c.add`/`c.slli` with rd = x0, zero shifts),
    /// `c.mop.N`, and `c.ntl.*`, which have no 32-bit equivalent and print compressed.
    public static func uncompress(_ inst: RV64Instruction) -> RV64Instruction? {
        let rd = inst.rd, rs1 = inst.rs1, rs2 = inst.rs2, imm = inst.imm
        let zero: UInt8 = 0, ra: UInt8 = 1, sp: UInt8 = 2
        func op(_ o: RV64Opcode, rd: UInt8 = 0, rs1: UInt8 = 0, rs2: UInt8 = 0, imm: Int64 = 0) -> RV64Instruction {
            RV64Instruction(opcode: o, rd: rd, rs1: rs1, rs2: rs2, imm: imm)
        }
        switch inst.opcode {
        case .c_nop: return imm == 0 ? op(.addi) : nil
        case .c_addi: return imm == 0 ? nil : op(.addi, rd: rd, rs1: rd, imm: imm)
        case .c_addiw: return op(.addiw, rd: rd, rs1: rd, imm: imm)
        case .c_li: return rd == zero ? nil : op(.addi, rd: rd, rs1: zero, imm: imm)
        case .c_lui: return rd == zero ? nil : op(.lui, rd: rd, imm: imm & 0xFFFFF)
        case .c_addi16sp: return op(.addi, rd: sp, rs1: sp, imm: imm)
        case .c_addi4spn: return op(.addi, rd: rd, rs1: sp, imm: imm)
        case .c_slli: return rd == zero || imm == 0 ? nil : op(.slli, rd: rd, rs1: rd, imm: imm)
        case .c_srli: return imm == 0 ? nil : op(.srli, rd: rd, rs1: rd, imm: imm)
        case .c_srai: return imm == 0 ? nil : op(.srai, rd: rd, rs1: rd, imm: imm)
        case .c_andi: return op(.andi, rd: rd, rs1: rd, imm: imm)
        case .c_sub: return op(.sub, rd: rd, rs1: rd, rs2: rs2)
        case .c_xor: return op(.xor, rd: rd, rs1: rd, rs2: rs2)
        case .c_or: return op(.or, rd: rd, rs1: rd, rs2: rs2)
        case .c_and: return op(.and, rd: rd, rs1: rd, rs2: rs2)
        case .c_subw: return op(.subw, rd: rd, rs1: rd, rs2: rs2)
        case .c_addw: return op(.addw, rd: rd, rs1: rd, rs2: rs2)
        case .c_mul: return op(.mul, rd: rd, rs1: rd, rs2: rs2)
        case .c_mv: return rd == zero ? nil : op(.addi, rd: rd, rs1: rs2)
        case .c_add: return rd == zero ? nil : op(.add, rd: rd, rs1: rd, rs2: rs2)
        case .c_jr: return op(.jalr, rd: zero, rs1: rs1)
        case .c_jalr: return op(.jalr, rd: ra, rs1: rs1)
        case .c_ebreak: return op(.ebreak)
        case .c_lw, .c_lwsp: return op(.lw, rd: rd, rs1: rs1, imm: imm)
        case .c_ld, .c_ldsp: return op(.ld, rd: rd, rs1: rs1, imm: imm)
        case .c_fld, .c_fldsp: return op(.fld, rd: rd, rs1: rs1, imm: imm)
        case .c_sw, .c_swsp: return op(.sw, rs1: rs1, rs2: rs2, imm: imm)
        case .c_sd, .c_sdsp: return op(.sd, rs1: rs1, rs2: rs2, imm: imm)
        case .c_fsd, .c_fsdsp: return op(.fsd, rs1: rs1, rs2: rs2, imm: imm)
        case .c_lbu: return op(.lbu, rd: rd, rs1: rs1, imm: imm)
        case .c_lhu: return op(.lhu, rd: rd, rs1: rs1, imm: imm)
        case .c_lh: return op(.lh, rd: rd, rs1: rs1, imm: imm)
        case .c_sb: return op(.sb, rs1: rs1, rs2: rs2, imm: imm)
        case .c_sh: return op(.sh, rs1: rs1, rs2: rs2, imm: imm)
        case .c_j: return op(.jal, rd: zero, imm: imm)
        case .c_beqz: return op(.beq, rs1: rs1, rs2: zero, imm: imm)
        case .c_bnez: return op(.bne, rs1: rs1, rs2: zero, imm: imm)
        case .c_zext_b: return op(.andi, rd: rd, rs1: rd, imm: 255)
        case .c_sext_b: return op(.sext_b, rd: rd, rs1: rd)
        case .c_zext_h: return op(.zext_h, rd: rd, rs1: rd)
        case .c_sext_h: return op(.sext_h, rd: rd, rs1: rd)
        case .c_zext_w: return op(.add_uw, rd: rd, rs1: rd, rs2: zero)
        case .c_not: return op(.xori, rd: rd, rs1: rd, imm: -1)
        default: return nil
        }
    }

    /// LLVM MC's preferred alias of a 32-bit instruction (an `InstAlias` with a nonzero emit priority in the
    /// RISC-V target), or `nil` when it prints under its own mnemonic.
    private static func preferredAlias(_ inst: RV64Instruction) -> String? {
        let rd = inst.rd & 0x1F, rs1 = inst.rs1 & 0x1F, rs2 = inst.rs2 & 0x1F, imm = inst.imm
        func x(_ r: UInt8) -> String { RVGPR(rawValue: r)!.abiName }
        func f(_ r: UInt8) -> String { RVFPR(rawValue: r)!.abiName }
        func v(_ r: UInt8) -> String { RVVReg(rawValue: r)!.name }
        let vmask = inst.vm ? "" : ", v0.t"
        let csr = RVCSR(unchecked: UInt16(imm & 0xFFF))
        switch inst.opcode {
        case .addi:
            if rd == 0 && rs1 == 0 && imm == 0 { return "nop" }
            if rs1 == 0 { return "li \(x(rd)), \(imm)" }
            if imm == 0 { return "mv \(x(rd)), \(x(rs1))" }
        case .addiw where imm == 0: return "sext.w \(x(rd)), \(x(rs1))"
        case .xori where imm == -1: return "not \(x(rd)), \(x(rs1))"
        case .sltiu where imm == 1: return "seqz \(x(rd)), \(x(rs1))"
        case .andi where imm == 255: return "zext.b \(x(rd)), \(x(rs1))"
        case .sub where rs1 == 0: return "neg \(x(rd)), \(x(rs2))"
        case .subw where rs1 == 0: return "negw \(x(rd)), \(x(rs2))"
        case .sltu where rs1 == 0: return "snez \(x(rd)), \(x(rs2))"
        case .slt:
            if rs2 == 0 { return "sltz \(x(rd)), \(x(rs1))" }
            if rs1 == 0 { return "sgtz \(x(rd)), \(x(rs2))" }
        case .add_uw where rs2 == 0: return "zext.w \(x(rd)), \(x(rs1))"
        case .beq where rs2 == 0: return "beqz \(x(rs1)), \(imm)"
        case .bne where rs2 == 0: return "bnez \(x(rs1)), \(imm)"
        case .blt:
            if rs2 == 0 { return "bltz \(x(rs1)), \(imm)" }
            if rs1 == 0 { return "bgtz \(x(rs2)), \(imm)" }
        case .bge:
            if rs1 == 0 { return "blez \(x(rs2)), \(imm)" }
            if rs2 == 0 { return "bgez \(x(rs1)), \(imm)" }
        case .jal:
            if rd == 0 { return "j \(imm)" }
            if rd == 1 { return "jal \(imm)" }
        case .jalr:
            let target = imm == 0 ? x(rs1) : "\(imm)(\(x(rs1)))"
            if rd == 0 { return rs1 == 1 && imm == 0 ? "ret" : "jr \(target)" }
            if rd == 1 { return "jalr \(target)" }
            return "jalr \(x(rd)), \(target)"
        case .fence where imm == 0xFF: return "fence"
        case .sfence_vma, .hfence_vvma, .hfence_gvma:
            if rs2 == 0 { return rs1 == 0 ? RV64InstructionTable.descriptor(for: inst.opcode).mnemonic
                                          : "\(RV64InstructionTable.descriptor(for: inst.opcode).mnemonic) \(x(rs1))" }
        case .csrrs:
            if rs1 == 0 {
                switch csr {
                case .cycle: return "rdcycle \(x(rd))"
                case .time: return "rdtime \(x(rd))"
                case .instret: return "rdinstret \(x(rd))"
                case .fcsr: return "frcsr \(x(rd))"
                case .frm: return "frrm \(x(rd))"
                case .fflags: return "frflags \(x(rd))"
                default: return "csrr \(x(rd)), \(csr)"
                }
            }
            if rd == 0 { return "csrs \(csr), \(x(rs1))" }
        case .csrrw:
            let fpName: String? = csr == .fcsr ? "fscsr" : csr == .frm ? "fsrm" : csr == .fflags ? "fsflags" : nil
            if rd == 0 {
                if csr == .cycle && rs1 == 0 { return "unimp" }
                return fpName.map { "\($0) \(x(rs1))" } ?? "csrw \(csr), \(x(rs1))"
            }
            if let fpName { return "\(fpName) \(x(rd)), \(x(rs1))" }
        case .csrrc where rd == 0: return "csrc \(csr), \(x(rs1))"
        case .csrrwi:
            let fpName: String? = csr == .frm ? "fsrmi" : csr == .fflags ? "fsflagsi" : nil
            if rd == 0 { return fpName.map { "\($0) \(rs1)" } ?? "csrwi \(csr), \(rs1)" }
            if let fpName { return "\(fpName) \(x(rd)), \(rs1)" }
        case .csrrsi where rd == 0: return "csrsi \(csr), \(rs1)"
        case .csrrci where rd == 0: return "csrci \(csr), \(rs1)"
        case .fsgnj_s where rs1 == rs2: return "fmv.s \(f(rd)), \(f(rs1))"
        case .fsgnjn_s where rs1 == rs2: return "fneg.s \(f(rd)), \(f(rs1))"
        case .fsgnjx_s where rs1 == rs2: return "fabs.s \(f(rd)), \(f(rs1))"
        case .fsgnj_d where rs1 == rs2: return "fmv.d \(f(rd)), \(f(rs1))"
        case .fsgnjn_d where rs1 == rs2: return "fneg.d \(f(rd)), \(f(rs1))"
        case .fsgnjx_d where rs1 == rs2: return "fabs.d \(f(rd)), \(f(rs1))"
        case .vl1re8_v: return "vl1r.v \(v(rd)), (\(x(rs1)))"
        case .vl2re8_v: return "vl2r.v \(v(rd)), (\(x(rs1)))"
        case .vl4re8_v: return "vl4r.v \(v(rd)), (\(x(rs1)))"
        case .vl8re8_v: return "vl8r.v \(v(rd)), (\(x(rs1)))"
        case .vfsgnjn_vv where rs1 == rs2: return "vfneg.v \(v(rd)), \(v(rs2))\(vmask)"
        case .vfsgnjx_vv where rs1 == rs2: return "vfabs.v \(v(rd)), \(v(rs2))\(vmask)"
        case .vrsub_vx where rs1 == 0: return "vneg.v \(v(rd)), \(v(rs2))\(vmask)"
        case .vxor_vi where imm == -1: return "vnot.v \(v(rd)), \(v(rs2))\(vmask)"
        case .vnsrl_wx where rs1 == 0: return "vncvt.x.x.w \(v(rd)), \(v(rs2))\(vmask)"
        case .vwaddu_vx where rs1 == 0: return "vwcvtu.x.x.v \(v(rd)), \(v(rs2))\(vmask)"
        case .vwadd_vx where rs1 == 0: return "vwcvt.x.x.v \(v(rd)), \(v(rs2))\(vmask)"
        case .vmand_mm where rs1 == rs2: return "vmmv.m \(v(rd)), \(v(rs2))"
        case .vmnand_mm where rs1 == rs2: return "vmnot.m \(v(rd)), \(v(rs2))"
        case .vmxor_mm where rd == rs1 && rs1 == rs2: return "vmclr.m \(v(rd))"
        case .vmxnor_mm where rd == rs1 && rs1 == rs2: return "vmset.m \(v(rd))"
        default:
            break
        }
        return nil
    }

    /// The canonical text of `inst` under its own mnemonic (no alias).
    private static func canonicalText(_ inst: RV64Instruction) -> String {
        let desc = RV64InstructionTable.descriptor(for: inst.opcode)
        let m = desc.mnemonic
        let gprRd = RVGPR(rawValue: inst.rd & 0x1F)!.abiName
        let gprRs1 = RVGPR(rawValue: inst.rs1 & 0x1F)!.abiName
        let gprRs2 = RVGPR(rawValue: inst.rs2 & 0x1F)!.abiName
        let fprRd = RVFPR(rawValue: inst.rd & 0x1F)!.abiName
        let fprRs1 = RVFPR(rawValue: inst.rs1 & 0x1F)!.abiName
        let fprRs2 = RVFPR(rawValue: inst.rs2 & 0x1F)!.abiName
        let vRd = RVVReg(rawValue: inst.rd & 0x1F)!.name
        let vRs1 = RVVReg(rawValue: inst.rs1 & 0x1F)!.name
        let vRs2 = RVVReg(rawValue: inst.rs2 & 0x1F)!.name

        // Rounding-mode operand: omitted when it is the instruction's default (`dyn`, or `rne` for `frmarglegacy`).
        let defaultRM: RVRoundingMode = desc.flags.contains(.rmDefaultRNE) ? .rne : .dyn
        let rm = inst.rm == defaultRM ? "" : ", \(inst.rm)"
        // RVV mask operand: `, v0.t` when masked, `, v0` when `vm` is fixed to 0 (carry-in / merge mask).
        let vmask: String
        if desc.isMaskable {
            vmask = inst.vm ? "" : ", v0.t"
        } else {
            vmask = desc.readsV0Implicitly ? ", v0" : ""
        }

        switch desc.format {
        case .r:
            return "\(m) \(gprRd), \(gprRs1), \(gprRs2)"

        case .rUnary:
            return "\(m) \(gprRd), \(gprRs1)"

        case .rShift64, .rShift32:
            return "\(m) \(gprRd), \(gprRs1), \(inst.imm)"

        case .rAMO, .rLR:
            var suffix = ""
            if inst.aq && inst.rl { suffix = ".aqrl" }
            else if inst.aq { suffix = ".aq" }
            else if inst.rl { suffix = ".rl" }
            if desc.format == .rLR {
                return "\(m)\(suffix) \(gprRd), (\(gprRs1))"
            }
            return "\(m)\(suffix) \(gprRd), \(gprRs2), (\(gprRs1))"

        case .rFP:
            return "\(m) \(fprRd), \(fprRs1), \(fprRs2)\(rm)"

        case .rFMA:
            let fprRs3 = RVFPR(rawValue: inst.rs3 & 0x1F)!.abiName
            return "\(m) \(fprRd), \(fprRs1), \(fprRs2), \(fprRs3)\(rm)"

        case .rFPFixed:
            return "\(m) \(fprRd), \(fprRs1), \(fprRs2)"

        case .rFPUnary:
            return "\(m) \(fprRd), \(fprRs1)\(rm)"

        case .rFPCmp:
            return "\(m) \(gprRd), \(fprRs1), \(fprRs2)"

        case .rFPCvtF2I:
            return "\(m) \(gprRd), \(fprRs1)\(rm)"

        case .rFPCvtMod:
            return "\(m) \(gprRd), \(fprRs1), rtz"

        case .rFPCvtI2F:
            return "\(m) \(fprRd), \(gprRs1)\(rm)"

        case .rFPMvF2I:
            return "\(m) \(gprRd), \(fprRs1)"

        case .rFPMvI2F:
            return "\(m) \(fprRd), \(gprRs1)"

        case .rFLI:
            return "\(m) \(fprRd), \(RVZfaFLITable.names[Int(inst.imm & 0x1F)])"

        case .i:
            return "\(m) \(gprRd), \(gprRs1), \(inst.imm)"

        case .iLoad:
            return "\(m) \(gprRd), \(inst.imm)(\(gprRs1))"

        case .iFPLoad:
            return "\(m) \(fprRd), \(inst.imm)(\(gprRs1))"

        case .s:
            return "\(m) \(gprRs2), \(inst.imm)(\(gprRs1))"

        case .sFP:
            return "\(m) \(fprRs2), \(inst.imm)(\(gprRs1))"

        case .b:
            return "\(m) \(gprRs1), \(gprRs2), \(inst.imm)"

        case .u:
            // Print the 20-bit field even when `imm` holds the full shifted value.
            let imm = inst.imm
            let u20 = ((imm & 0xFFF) == 0 && (imm > 0xFFFFF || imm < -0x80000)) ? (imm >> 12) & 0xFFFFF : imm & 0xFFFFF
            return "\(m) \(gprRd), \(u20)"

        case .j:
            return "\(m) \(gprRd), \(inst.imm)"

        case .fence:
            let imm8 = UInt8(truncatingIfNeeded: inst.imm)
            return "fence \(RVFenceMask(rawValue: imm8 >> 4)), \(RVFenceMask(rawValue: imm8 & 0xF))"

        case .csrReg:
            return "\(m) \(gprRd), \(RVCSR(unchecked: UInt16(inst.imm & 0xFFF))), \(gprRs1)"

        case .csrImm:
            return "\(m) \(gprRd), \(RVCSR(unchecked: UInt16(inst.imm & 0xFFF))), \(inst.rs1)"

        case .systemFixed, .cFixed:
            return m

        case .cNop:
            return inst.imm == 0 ? m : "\(m) \(inst.imm)"

        case .sfenceVMA:
            return "\(m) \(gprRs1), \(gprRs2)"

        case .cbo:
            return "\(m) (\(gprRs1))"

        case .prefetch:
            return "\(m) \(inst.imm)(\(gprRs1))"

        case .hlv:
            return "\(m) \(gprRd), (\(gprRs1))"

        case .hsv:
            return "\(m) \(gprRs2), (\(gprRs1))"

        case .vsetvli:
            return "vsetvli \(gprRd), \(gprRs1), \(RVVType(rawValue: UInt16(inst.imm & 0x7FF)))"

        case .vsetivli:
            return "vsetivli \(gprRd), \(inst.rs1), \(RVVType(rawValue: UInt16(inst.imm & 0x3FF)))"

        case .vsetvl:
            return "vsetvl \(gprRd), \(gprRs1), \(gprRs2)"

        case .vLoadUnit, .vStoreUnit, .vLoadWhole, .vStoreWhole:
            return "\(m) \(vRd), (\(gprRs1))\(vmask)"

        case .vLoadStrided, .vStoreStrided:
            return "\(m) \(vRd), (\(gprRs1)), \(gprRs2)\(vmask)"

        case .vLoadIndexed, .vStoreIndexed:
            return "\(m) \(vRd), (\(gprRs1)), \(vRs2)\(vmask)"

        case .vVV:
            return "\(m) \(vRd), \(vRs2), \(vRs1)\(vmask)"

        case .vVX:
            return "\(m) \(vRd), \(vRs2), \(gprRs1)\(vmask)"

        case .vVF:
            return "\(m) \(vRd), \(vRs2), \(fprRs1)\(vmask)"

        case .vVI, .vVUI, .vVUI6:
            return "\(m) \(vRd), \(vRs2), \(inst.imm)\(vmask)"

        case .vMAccVV:
            return "\(m) \(vRd), \(vRs1), \(vRs2)\(vmask)"

        case .vMAccVX:
            return "\(m) \(vRd), \(gprRs1), \(vRs2)\(vmask)"

        case .vMAccVF:
            return "\(m) \(vRd), \(fprRs1), \(vRs2)\(vmask)"

        case .vUnary:
            return "\(m) \(vRd), \(vRs2)\(vmask)"

        case .vNullary:
            return "\(m) \(vRd)\(vmask)"

        case .vToX:
            return "\(m) \(gprRd), \(vRs2)\(vmask)"

        case .vToF:
            return "\(m) \(fprRd), \(vRs2)"

        case .vMvVV:
            return "\(m) \(vRd), \(vRs1)"

        case .vMvVX:
            return "\(m) \(vRd), \(gprRs1)"

        case .vMvVI:
            return "\(m) \(vRd), \(inst.imm)"

        case .vMvVF:
            return "\(m) \(vRd), \(fprRs1)"

        case .cAddi, .cShift, .cAndi, .cSlli:
            return "\(m) \(gprRd), \(inst.imm)"

        case .cLui:
            // LLVM MC takes the 20-bit form of a negative c.lui immediate (0xfffe0..0xfffff).
            return "\(m) \(gprRd), \(inst.imm < 0 ? inst.imm & 0xFFFFF : inst.imm)"

        case .cAddi16sp:
            return "c.addi16sp sp, \(inst.imm)"

        case .cAddi4spn:
            return "c.addi4spn \(gprRd), sp, \(inst.imm)"

        case .cAlu, .cCR:
            return "\(m) \(gprRd), \(gprRs2)"

        case .cZcbUnary:
            return "\(m) \(gprRd)"

        case .cJr:
            return "\(m) \(gprRs1)"

        case .cLw, .cLd:
            return "\(m) \(gprRd), \(inst.imm)(\(gprRs1))"

        case .cFld:
            return "c.fld \(fprRd), \(inst.imm)(\(gprRs1))"

        case .cSw, .cSd:
            return "\(m) \(gprRs2), \(inst.imm)(\(gprRs1))"

        case .cFsd:
            return "c.fsd \(fprRs2), \(inst.imm)(\(gprRs1))"

        case .cLwsp, .cLdsp:
            return "\(m) \(gprRd), \(inst.imm)(sp)"

        case .cFldsp:
            return "c.fldsp \(fprRd), \(inst.imm)(sp)"

        case .cSwsp, .cSdsp:
            return "\(m) \(gprRs2), \(inst.imm)(sp)"

        case .cFsdsp:
            return "c.fsdsp \(fprRs2), \(inst.imm)(sp)"

        case .cJ:
            return "c.j \(inst.imm)"

        case .cBranch:
            return "\(m) \(gprRs1), \(inst.imm)"

        case .cZcbByte, .cZcbHalf:
            if desc.opcode == .c_sb || desc.opcode == .c_sh {
                return "\(m) \(gprRs2), \(inst.imm)(\(gprRs1))"
            }
            return "\(m) \(gprRd), \(inst.imm)(\(gprRs1))"
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
        // Distinct, 8-aligned vector registers satisfy every overlap and register-group rule.
        let v8 = RVVReg.v8.rawValue
        let v16 = RVVReg.v16.rawValue
        let v24 = RVVReg.v24.rawValue

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
        case .systemFixed, .cFixed, .cNop:
            return RV64Instruction(opcode: desc.opcode)
        case .sfenceVMA, .hsv:
            return RV64Instruction(opcode: desc.opcode, rs1: a0, rs2: a1)
        case .rFMA:
            return RV64Instruction(opcode: desc.opcode, rd: fa0, rs1: fa1, rs2: fa2, rs3: RVFPR.fa3.rawValue, rm: .rne)
        case .rFPCvtMod:
            return RV64Instruction(opcode: desc.opcode, rd: a0, rs1: fa1, rm: .rtz)
        case .cbo:
            return RV64Instruction(opcode: desc.opcode, rs1: a0)
        case .prefetch:
            return RV64Instruction(opcode: desc.opcode, rs1: a0, imm: -64)
        case .hlv:
            return RV64Instruction(opcode: desc.opcode, rd: a0, rs1: a1)
        case .vsetvli:
            let vt = RVVType(sewBits: 64, lmulBits: 0, tailAgnostic: true, maskAgnostic: true)!
            return RV64Instruction(opcode: .vsetvli, rd: a0, rs1: a1, imm: Int64(vt.rawValue))
        case .vsetivli:
            let vt = RVVType(sewBits: 32, lmulBits: 0, tailAgnostic: true, maskAgnostic: true)!
            return RV64Instruction(opcode: .vsetivli, rd: a0, rs1: 8, imm: Int64(vt.rawValue))
        case .vsetvl:
            return RV64Instruction(opcode: .vsetvl, rd: a0, rs1: a1, rs2: a2)
        case .vLoadUnit, .vStoreUnit, .vLoadWhole, .vStoreWhole:
            return RV64Instruction(opcode: desc.opcode, rd: v8, rs1: a0, vm: true)
        case .vLoadStrided, .vStoreStrided:
            return RV64Instruction(opcode: desc.opcode, rd: v8, rs1: a0, rs2: a1, vm: true)
        case .vLoadIndexed, .vStoreIndexed, .vVV, .vMAccVV:
            return RV64Instruction(opcode: desc.opcode, rd: v8, rs1: v24, rs2: v16, vm: true)
        case .vVX, .vVF, .vMAccVX, .vMAccVF:
            return RV64Instruction(opcode: desc.opcode, rd: v8, rs1: a0, rs2: v16, vm: true)
        case .vVI:
            return RV64Instruction(opcode: desc.opcode, rd: v8, rs2: v16, imm: -5, vm: true)
        case .vVUI, .vVUI6:
            return RV64Instruction(opcode: desc.opcode, rd: v8, rs2: v16, imm: 13, vm: true)
        case .vUnary, .vNullary:
            return RV64Instruction(opcode: desc.opcode, rd: v8, rs2: v16, vm: true)
        case .vToX, .vToF:
            return RV64Instruction(opcode: desc.opcode, rd: a0, rs2: v16, vm: true)
        case .vMvVV:
            return RV64Instruction(opcode: desc.opcode, rd: v8, rs1: v24, vm: true)
        case .vMvVX, .vMvVF:
            return RV64Instruction(opcode: desc.opcode, rd: v8, rs1: a0, vm: true)
        case .vMvVI:
            return RV64Instruction(opcode: desc.opcode, rd: v8, imm: 7, vm: true)
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
            if let problem = RV64Encoder.validate(sample) {
                preconditionFailure("Invalid sample for \(desc.mnemonic): \(problem)")
            }
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
