// Sources/SwiftStack/Sem/DataLayout.swift
import Foundation

/// The C data layout of one target (02-semantic-analysis.md §4.1, §4.2.2): sizes and alignments of the scalar types,
/// the `long double` format, the `_BitInt(N)` rule of the target's psABI, `char` signedness, and the types behind
/// `wchar_t`, `size_t` and `ptrdiff_t`. The TypePool is built from one layout per compilation, and struct layout
/// reads member sizes and alignments from it.
///
/// Every value matches clang 22 for `x86_64-linux-gnu`, `aarch64-linux-gnu` and `riscv64-linux-gnu` (and their
/// `-unknown-none-elf` forms, which VectraOS uses); the probe differential in `M3SemIRTests` checks them.
public struct DataLayout: Sendable, Equatable {
    /// Encoding of `long double`.
    public enum LongDoubleFormat: Sendable, Equatable {
        /// The x87 80-bit extended format (64-bit significand with an explicit integer bit), stored in 16 bytes.
        case x87Extended
        /// IEEE 754 binary128 (113-bit significand).
        case ieeeQuad
    }

    /// How `_BitInt(N)` with N > 64 is laid out (N ≤ 64 takes the smallest of 1, 2, 4 or 8 bytes on every target).
    public enum BitIntRule: Sendable, Equatable {
        /// x86-64 psABI: 8-byte words, 8-byte aligned. Clang 22 lays RISC-V out the same way.
        case words64
        /// AAPCS64: 16-byte chunks, 16-byte aligned.
        case chunks128
    }

    public let arch: AssemblerArch
    public let pointerSize: Int
    public let longSize: Int
    public let longDoubleFormat: LongDoubleFormat
    public let bitIntRule: BitIntRule
    /// `BITINT_MAXWIDTH`: clang 22 allows `_BitInt` above 128 bits only on x86-64, where Swift-Stack caps it at 8192.
    public let bitIntMaxWidth: Int
    /// Plain `char` is signed on x86-64 and unsigned on AArch64 and RISC-V (`__CHAR_UNSIGNED__`).
    public let charIsSigned: Bool
    /// `wchar_t` (`__WCHAR_TYPE__`): `int` on x86-64 and RISC-V, `unsigned int` on AArch64.
    public let wcharType: TypeId
    /// `wint_t` (`__WINT_TYPE__`) for hosted Linux targets.
    public let wintType: TypeId
    /// `size_t` and `ptrdiff_t` (`unsigned long` and `long` on every LP64 target).
    public let sizeType: TypeId
    public let ptrdiffType: TypeId
    /// `_Alignof(max_align_t)`, also `__BIGGEST_ALIGNMENT__` and the default of `__attribute__((aligned))`.
    public let maxAlignment: Int
    /// AAPCS64 bit-field alignment (clang's `useZeroLengthBitfieldAlignment`): unnamed bit-fields count toward the
    /// alignment of the enclosing structure or union as named ones do, and a zero-width one raises it to its declared
    /// type's alignment even in a packed record. On x86-64 and RISC-V unnamed bit-fields do not affect alignment, and
    /// a zero-width one only closes the storage unit.
    public let unnamedBitFieldsAlign: Bool

    public static let x86_64 = DataLayout(
        arch: .x86_64, pointerSize: 8, longSize: 8, longDoubleFormat: .x87Extended, bitIntRule: .words64, bitIntMaxWidth: 8192,
        charIsSigned: true, wcharType: .int, wintType: .uint, sizeType: .ulong, ptrdiffType: .long, maxAlignment: 16,
        unnamedBitFieldsAlign: false)

    public static let aarch64 = DataLayout(
        arch: .aarch64, pointerSize: 8, longSize: 8, longDoubleFormat: .ieeeQuad, bitIntRule: .chunks128, bitIntMaxWidth: 128,
        charIsSigned: false, wcharType: .uint, wintType: .uint, sizeType: .ulong, ptrdiffType: .long, maxAlignment: 16,
        unnamedBitFieldsAlign: true)

    public static let riscv64 = DataLayout(
        arch: .riscv64, pointerSize: 8, longSize: 8, longDoubleFormat: .ieeeQuad, bitIntRule: .words64, bitIntMaxWidth: 128,
        charIsSigned: false, wcharType: .int, wintType: .uint, sizeType: .ulong, ptrdiffType: .long, maxAlignment: 16,
        unnamedBitFieldsAlign: false)

    public static func forArch(_ arch: AssemblerArch) -> DataLayout {
        switch arch {
        case .x86_64: return .x86_64
        case .aarch64: return .aarch64
        case .riscv64: return .riscv64
        }
    }

    /// The layout of the architecture named by `arch` (`x86_64`, `aarch64`/`arm64`, `riscv64`/`rv64`), or of the
    /// first component of a target triple.
    public static func forArchName(_ arch: String) -> DataLayout {
        let lower = arch.lowercased()
        if lower.hasPrefix("aarch64") || lower.hasPrefix("arm64") { return .aarch64 }
        if lower.hasPrefix("riscv64") || lower.hasPrefix("rv64") { return .riscv64 }
        return .x86_64
    }

    /// Bits of precision of `long double`'s significand (`__LDBL_MANT_DIG__`).
    public var longDoubleMantissaDigits: Int { longDoubleFormat == .x87Extended ? 64 : 113 }

    /// Size and alignment in bytes of `_BitInt(width)` (C23 6.2.5; x86-64 psABI §3.1.2, AAPCS64 §5.1.1).
    public func bitIntLayout(width: Int) -> (size: Int, alignment: Int) {
        switch width {
        case ...8: return (1, 1)
        case ...16: return (2, 2)
        case ...32: return (4, 4)
        case ...64: return (8, 8)
        default:
            switch bitIntRule {
            case .words64: return ((width + 63) / 64 * 8, 8)
            case .chunks128: return ((width + 127) / 128 * 16, 16)
            }
        }
    }
}
