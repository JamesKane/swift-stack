// Sources/SwiftStack/Sem/SoftFloat.swift
//
// Exact, host-independent binary floating point for constant evaluation (02-semantic-analysis.md §4.2.3): IEEE 754
// binary16/32/64/128 and the x87 80-bit extended format. Every operation computes the exact result and rounds it
// once to the format, to nearest with ties to even, as clang's APFloat folds C constants; so `float`, `double` and
// `long double` initializers fold to the same bits as clang's on any host (D6).

import Foundation

/// A binary floating-point format.
public struct FloatFormat: Sendable, Equatable, Hashable {
    /// Significand bits, including the leading bit.
    public let precision: Int
    public let exponentBits: Int
    /// Whether the encoding stores the leading significand bit (x87).
    public let explicitLeadingBit: Bool
    /// Bytes the encoding occupies (the x87 format's 10).
    public let encodedBytes: Int

    public var bias: Int { (1 << (exponentBits - 1)) - 1 }
    public var minExponent: Int { 1 - bias }
    public var maxExponent: Int { bias }

    public static let half = FloatFormat(precision: 11, exponentBits: 5, explicitLeadingBit: false, encodedBytes: 2)
    public static let single = FloatFormat(precision: 24, exponentBits: 8, explicitLeadingBit: false, encodedBytes: 4)
    public static let double = FloatFormat(precision: 53, exponentBits: 11, explicitLeadingBit: false, encodedBytes: 8)
    public static let x87Extended = FloatFormat(precision: 64, exponentBits: 15, explicitLeadingBit: true, encodedBytes: 10)
    public static let quad = FloatFormat(precision: 113, exponentBits: 15, explicitLeadingBit: false, encodedBytes: 16)
}

/// A floating-point value of a format: zero, a finite nonzero value `significand × 2^exponent` (the significand
/// has at most `precision` bits), an infinity, or a NaN.
public struct SoftFloat: Sendable, Equatable {
    public enum Category: Sendable, Equatable { case zero, finite, infinity, nan }

    public let format: FloatFormat
    public let isNegative: Bool
    public let category: Category
    public let significand: BigUInt
    public let exponent: Int

    init(format: FloatFormat, isNegative: Bool, category: Category, significand: BigUInt = BigUInt(), exponent: Int = 0) {
        self.format = format
        self.isNegative = isNegative
        self.category = category
        self.significand = significand
        self.exponent = exponent
    }

    public static func zero(_ format: FloatFormat, negative: Bool = false) -> SoftFloat {
        SoftFloat(format: format, isNegative: negative, category: .zero)
    }

    public static func infinity(_ format: FloatFormat, negative: Bool = false) -> SoftFloat {
        SoftFloat(format: format, isNegative: negative, category: .infinity)
    }

    /// The default quiet NaN (`__builtin_nan("")`).
    public static func nan(_ format: FloatFormat, negative: Bool = false) -> SoftFloat {
        SoftFloat(format: format, isNegative: negative, category: .nan)
    }

    public var isZero: Bool { category == .zero }
    public var isNaN: Bool { category == .nan }

    /// Rounds the exact value `±mant × 2^exp` (with `sticky` set if nonzero bits below `mant` were dropped) to `format`.
    public static func round(_ format: FloatFormat, negative: Bool, mant: BigUInt, exp: Int, sticky: Bool = false) -> SoftFloat {
        guard !mant.isZero else {
            // Only the sticky bits are left: a value below every representable magnitude rounds to zero
            return .zero(format, negative: negative)
        }
        let p = format.precision
        let top = exp + mant.bitLength - 1  // exponent of the leading bit
        // The exponent of the result's least significant bit: the precision below the leading bit, or the subnormal
        // quantum below the normal range
        let lsb = max(top, format.minExponent) - (p - 1)
        var m = mant
        var e = exp
        if lsb > e {
            let drop = lsb - e
            let half = m.bit(drop - 1)
            let rest = sticky || m.anyBitBelow(drop - 1)
            m = m >> drop
            e = lsb
            if half && (rest || m.bit(0)) {
                m = m.adding(small: 1)
                if m.bitLength > p {  // carried into a new leading bit
                    m = m >> 1
                    e += 1
                }
            }
        } else if lsb < e {
            m = m << (e - lsb)
            e = lsb
        }
        if m.isZero { return .zero(format, negative: negative) }
        if e + m.bitLength - 1 > format.maxExponent { return .infinity(format, negative: negative) }
        return SoftFloat(format: format, isNegative: negative, category: .finite, significand: m, exponent: e)
    }

    // MARK: - Conversions

    /// The integer `magnitude` (negated if `negative`) rounded to `format`.
    public static func fromInteger(_ magnitude: BigUInt, negative: Bool, format: FloatFormat) -> SoftFloat {
        round(format, negative: negative, mant: magnitude, exp: 0)
    }

    /// This value rounded to another format.
    public func converted(to f: FloatFormat) -> SoftFloat {
        switch category {
        case .zero: return .zero(f, negative: isNegative)
        case .infinity: return .infinity(f, negative: isNegative)
        case .nan: return .nan(f, negative: isNegative)
        case .finite: return SoftFloat.round(f, negative: isNegative, mant: significand, exp: exponent)
        }
    }

    /// The value truncated toward zero (C23 6.3.1.4p1), as a sign and magnitude; nil for an infinity or NaN.
    public func truncatedInteger() -> (negative: Bool, magnitude: BigUInt)? {
        switch category {
        case .zero: return (false, BigUInt())
        case .infinity, .nan: return nil
        case .finite:
            let m = exponent >= 0 ? significand << exponent : significand >> -exponent
            return (isNegative && !m.isZero, m)
        }
    }

    // MARK: - Arithmetic

    public func negated() -> SoftFloat {
        SoftFloat(format: format, isNegative: !isNegative, category: category, significand: significand, exponent: exponent)
    }

    public func adding(_ o: SoftFloat) -> SoftFloat {
        if isNaN || o.isNaN { return .nan(format) }
        if category == .infinity {
            if o.category == .infinity && o.isNegative != isNegative { return .nan(format) }
            return self
        }
        if o.category == .infinity { return o }
        if isZero && o.isZero { return .zero(format, negative: isNegative && o.isNegative) }
        if isZero { return o }
        if o.isZero { return self }
        let e = min(exponent, o.exponent)
        let a = significand << (exponent - e), b = o.significand << (o.exponent - e)
        if isNegative == o.isNegative {
            return SoftFloat.round(format, negative: isNegative, mant: a + b, exp: e)
        }
        if a == b { return .zero(format) }  // x + (-x) is +0 when rounding to nearest
        return a < b ? SoftFloat.round(format, negative: o.isNegative, mant: b - a, exp: e)
                     : SoftFloat.round(format, negative: isNegative, mant: a - b, exp: e)
    }

    public func subtracting(_ o: SoftFloat) -> SoftFloat { adding(o.negated()) }

    public func multiplied(by o: SoftFloat) -> SoftFloat {
        let neg = isNegative != o.isNegative
        if isNaN || o.isNaN { return .nan(format) }
        if category == .infinity || o.category == .infinity {
            return (isZero || o.isZero) ? .nan(format) : .infinity(format, negative: neg)
        }
        if isZero || o.isZero { return .zero(format, negative: neg) }
        return SoftFloat.round(format, negative: neg, mant: significand * o.significand, exp: exponent + o.exponent)
    }

    public func divided(by o: SoftFloat) -> SoftFloat {
        let neg = isNegative != o.isNegative
        if isNaN || o.isNaN { return .nan(format) }
        if category == .infinity { return o.category == .infinity ? .nan(format) : .infinity(format, negative: neg) }
        if o.category == .infinity { return .zero(format, negative: neg) }
        if o.isZero { return isZero ? .nan(format) : .infinity(format, negative: neg) }
        if isZero { return .zero(format, negative: neg) }
        // Enough quotient bits for the precision plus a guard bit; the remainder is the sticky bit
        let shift = max(0, format.precision + 2 + o.significand.bitLength - significand.bitLength)
        let (q, r) = (significand << shift).quotientAndRemainder(dividingBy: o.significand)
        return SoftFloat.round(format, negative: neg, mant: q, exp: exponent - o.exponent - shift, sticky: !r.isZero)
    }

    /// -1, 0 or 1; nil if unordered (a NaN).
    public func compare(_ o: SoftFloat) -> Int? {
        if isNaN || o.isNaN { return nil }
        func sign(_ x: SoftFloat) -> Int { x.isZero ? 0 : (x.isNegative ? -1 : 1) }
        let sa = sign(self), sb = sign(o)
        if sa != sb { return sa < sb ? -1 : 1 }
        if sa == 0 { return 0 }
        let mag: Int
        if category == .infinity || o.category == .infinity {
            mag = category == o.category ? 0 : (category == .infinity ? 1 : -1)
        } else {
            let e = min(exponent, o.exponent)
            let a = significand << (exponent - e), b = o.significand << (o.exponent - e)
            mag = a == b ? 0 : (a < b ? -1 : 1)
        }
        return sa > 0 ? mag : -mag
    }

    // MARK: - Encoding

    /// The IEEE (or x87) encoding, little-endian, in `format.encodedBytes` bytes.
    public func encoded() -> [UInt8] {
        let f = format
        let storedPrecision = f.explicitLeadingBit ? f.precision : f.precision - 1
        var field = BigUInt()  // the significand field
        var biased = 0
        switch category {
        case .zero:
            break
        case .infinity:
            biased = (1 << f.exponentBits) - 1
            if f.explicitLeadingBit { field = BigUInt(1) << (f.precision - 1) }
        case .nan:
            biased = (1 << f.exponentBits) - 1
            // Quiet NaN: the top fraction bit (and the x87 integer bit)
            field = BigUInt(1) << (storedPrecision - 1)
            if f.explicitLeadingBit { field = field + (BigUInt(1) << (f.precision - 1)) }
        case .finite:
            // Normalize the significand to `precision` bits
            let m = significand << (f.precision - significand.bitLength)
            let e = exponent - (f.precision - significand.bitLength)
            let top = e + f.precision - 1
            if top >= f.minExponent {
                biased = top + f.bias
                field = f.explicitLeadingBit ? m : m - (BigUInt(1) << (f.precision - 1))
            } else {
                // Subnormal: the significand at the minimum exponent's quantum
                biased = 0
                field = m >> (f.minExponent - top)
            }
        }
        var bits = field + (BigUInt(UInt64(biased)) << storedPrecision)
        if isNegative { bits = bits + (BigUInt(1) << (storedPrecision + f.exponentBits)) }
        var out = [UInt8](repeating: 0, count: f.encodedBytes)
        for i in 0..<f.encodedBytes {
            let limb = i / 8 < bits.limbs.count ? bits.limbs[i / 8] : 0
            out[i] = UInt8(truncatingIfNeeded: limb >> UInt64((i % 8) * 8))
        }
        return out
    }

    /// The encoding as a `FloatConstant` (low and high 64 bits).
    public var constant: FloatConstant {
        let bytes = encoded()
        var lo: UInt64 = 0, hi: UInt64 = 0
        for (i, b) in bytes.enumerated() {
            if i < 8 { lo |= UInt64(b) << UInt64(i * 8) } else { hi |= UInt64(b) << UInt64((i - 8) * 8) }
        }
        return FloatConstant(lo: lo, hi: hi)
    }

    /// Decodes an encoding (`FloatConstant`) of `format`.
    public static func decode(_ c: FloatConstant, format f: FloatFormat) -> SoftFloat {
        let all = BigUInt(limbs: [c.lo, c.hi])
        let storedPrecision = f.explicitLeadingBit ? f.precision : f.precision - 1
        let field = all.quotientAndRemainder(dividingBy: BigUInt(1) << storedPrecision).remainder
        let biased = Int((all >> storedPrecision).low64 & UInt64((1 << f.exponentBits) - 1))
        let negative = all.bit(storedPrecision + f.exponentBits)
        let maxBiased = (1 << f.exponentBits) - 1
        let fraction = f.explicitLeadingBit ? field.quotientAndRemainder(dividingBy: BigUInt(1) << (f.precision - 1)).remainder : field
        if biased == maxBiased {
            return fraction.isZero ? .infinity(f, negative: negative) : .nan(f, negative: negative)
        }
        if biased == 0 {
            if field.isZero { return .zero(f, negative: negative) }
            return round(f, negative: negative, mant: field, exp: f.minExponent - (f.precision - 1))
        }
        let mant = f.explicitLeadingBit ? field : field + (BigUInt(1) << (f.precision - 1))
        return round(f, negative: negative, mant: mant, exp: biased - f.bias - (f.precision - 1))
    }

    // MARK: - Parsing

    /// A C floating constant's value (C23 6.4.4.2), without its suffix and digit separators: decimal (`1.5e3`) or
    /// hexadecimal (`0x1.8p3`), correctly rounded to `format`. Nil if malformed.
    public static func parse(_ text: String, format: FloatFormat) -> SoftFloat? {
        var s = Array(text.utf8.filter { $0 != UInt8(ascii: "'") })
        guard !s.isEmpty else { return nil }
        let isHex = s.count > 2 && s[0] == UInt8(ascii: "0") && (s[1] | 0x20) == UInt8(ascii: "x")
        if isHex { s.removeFirst(2) }
        var mant = BigUInt()
        var fractionDigits = 0
        var sawDot = false, sawDigit = false
        var i = 0
        func digitValue(_ c: UInt8) -> UInt64? {
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return UInt64(c - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f") where isHex: return UInt64(c - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F") where isHex: return UInt64(c - UInt8(ascii: "A") + 10)
            default: return nil
            }
        }
        while i < s.count {
            if s[i] == UInt8(ascii: ".") && !sawDot {
                sawDot = true
            } else if let d = digitValue(s[i]) {
                mant = mant.multiplied(bySmall: isHex ? 16 : 10).adding(small: d)
                if sawDot { fractionDigits += 1 }
                sawDigit = true
            } else {
                break
            }
            i += 1
        }
        guard sawDigit else { return nil }
        var exp = 0
        if i < s.count {
            guard (s[i] | 0x20) == UInt8(ascii: isHex ? "p" : "e") else { return nil }
            i += 1
            var negativeExp = false
            if i < s.count && (s[i] == UInt8(ascii: "+") || s[i] == UInt8(ascii: "-")) {
                negativeExp = s[i] == UInt8(ascii: "-")
                i += 1
            }
            guard i < s.count else { return nil }
            var e = 0
            while i < s.count, let d = digitValue(s[i]), d < 10 {
                e = min(e * 10 + Int(d), 1_000_000)
                i += 1
            }
            guard i == s.count else { return nil }
            exp = negativeExp ? -e : e
        } else if isHex {
            return nil
        }
        if mant.isZero { return .zero(format) }
        if isHex { return round(format, negative: false, mant: mant, exp: exp - 4 * fractionDigits) }
        let decimalExp = exp - fractionDigits
        // Clamp absurd exponents: the result is already zero or infinity long before them
        if decimalExp > 10_000 { return .infinity(format) }
        if decimalExp < -10_000 - mant.bitLength { return .zero(format) }
        if decimalExp >= 0 { return round(format, negative: false, mant: mant * BigUInt.pow10(decimalExp), exp: 0) }
        let den = BigUInt.pow10(-decimalExp)
        let shift = max(0, format.precision + 3 + den.bitLength - mant.bitLength)
        let (q, r) = (mant << shift).quotientAndRemainder(dividingBy: den)
        return round(format, negative: false, mant: q, exp: -shift, sticky: !r.isZero)
    }
}
