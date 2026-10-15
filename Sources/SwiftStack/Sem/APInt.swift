// Sources/SwiftStack/Sem/APInt.swift
//
// Exact integer arithmetic for constant evaluation (02-semantic-analysis.md §4.2.3): `BigUInt`, an unbounded unsigned
// integer, and `APInt`, a fixed-width two's-complement integer of 1 to 8192 bits (`_BitInt(N)`, `__int128`). Both
// are host-independent, so constant folding gives the same bits on every host (D6). `SoftFloat` builds on `BigUInt`.

import Foundation

/// An unbounded unsigned integer: little-endian 64-bit limbs with no trailing zero limbs (zero has none).
public struct BigUInt: Sendable, Equatable, Hashable, Comparable, CustomStringConvertible {
    public private(set) var limbs: [UInt64]

    public init() { limbs = [] }

    public init(_ value: UInt64) {
        limbs = value == 0 ? [] : [value]
    }

    public init(limbs: [UInt64]) {
        self.limbs = limbs
        normalize()
    }

    private mutating func normalize() {
        while let last = limbs.last, last == 0 { limbs.removeLast() }
    }

    public var isZero: Bool { limbs.isEmpty }

    /// Number of significant bits (0 for zero).
    public var bitLength: Int {
        guard let last = limbs.last else { return 0 }
        return (limbs.count - 1) * 64 + (64 - last.leadingZeroBitCount)
    }

    public var low64: UInt64 { limbs.first ?? 0 }

    public func bit(_ i: Int) -> Bool {
        let w = i / 64
        guard i >= 0, w < limbs.count else { return false }
        return (limbs[w] >> UInt64(i % 64)) & 1 == 1
    }

    /// Whether any of the low `n` bits is set.
    public func anyBitBelow(_ n: Int) -> Bool {
        guard n > 0 else { return false }
        let full = n / 64
        for i in 0..<min(full, limbs.count) where limbs[i] != 0 { return true }
        let rem = n % 64
        if rem > 0, full < limbs.count, limbs[full] & ((UInt64(1) << UInt64(rem)) - 1) != 0 { return true }
        return false
    }

    public static func << (a: BigUInt, n: Int) -> BigUInt {
        guard n > 0, !a.isZero else { return n < 0 ? a >> -n : a }
        let words = n / 64, bits = UInt64(n % 64)
        var out = [UInt64](repeating: 0, count: a.limbs.count + words + 1)
        for (i, limb) in a.limbs.enumerated() {
            out[i + words] |= limb << bits
            if bits > 0 { out[i + words + 1] |= limb >> (64 - bits) }
        }
        return BigUInt(limbs: out)
    }

    public static func >> (a: BigUInt, n: Int) -> BigUInt {
        guard n > 0 else { return n < 0 ? a << -n : a }
        let words = n / 64, bits = UInt64(n % 64)
        guard words < a.limbs.count else { return BigUInt() }
        var out = [UInt64](repeating: 0, count: a.limbs.count - words)
        for i in 0..<out.count {
            let lo = a.limbs[i + words] >> bits
            let hi = (bits > 0 && i + words + 1 < a.limbs.count) ? a.limbs[i + words + 1] << (64 - bits) : 0
            out[i] = lo | hi
        }
        return BigUInt(limbs: out)
    }

    public static func + (a: BigUInt, b: BigUInt) -> BigUInt {
        var out = [UInt64](repeating: 0, count: max(a.limbs.count, b.limbs.count) + 1)
        var carry: UInt64 = 0
        for i in 0..<(out.count - 1) {
            let x = i < a.limbs.count ? a.limbs[i] : 0
            let y = i < b.limbs.count ? b.limbs[i] : 0
            let (s1, c1) = x.addingReportingOverflow(y)
            let (s2, c2) = s1.addingReportingOverflow(carry)
            out[i] = s2
            carry = (c1 ? 1 : 0) + (c2 ? 1 : 0)
        }
        out[out.count - 1] = carry
        return BigUInt(limbs: out)
    }

    /// `a - b`; requires `a >= b`.
    public static func - (a: BigUInt, b: BigUInt) -> BigUInt {
        var out = a.limbs
        var borrow: UInt64 = 0
        for i in 0..<out.count {
            let y = i < b.limbs.count ? b.limbs[i] : 0
            let (d1, b1) = out[i].subtractingReportingOverflow(y)
            let (d2, b2) = d1.subtractingReportingOverflow(borrow)
            out[i] = d2
            borrow = (b1 ? 1 : 0) + (b2 ? 1 : 0)
        }
        return BigUInt(limbs: out)
    }

    public static func * (a: BigUInt, b: BigUInt) -> BigUInt {
        guard !a.isZero, !b.isZero else { return BigUInt() }
        var out = [UInt64](repeating: 0, count: a.limbs.count + b.limbs.count)
        for (i, x) in a.limbs.enumerated() {
            var carry: UInt64 = 0
            for (j, y) in b.limbs.enumerated() {
                let (hi, lo) = x.multipliedFullWidth(by: y)
                let (s1, c1) = out[i + j].addingReportingOverflow(lo)
                let (s2, c2) = s1.addingReportingOverflow(carry)
                out[i + j] = s2
                carry = hi &+ (c1 ? 1 : 0) &+ (c2 ? 1 : 0)
            }
            var k = i + b.limbs.count
            while carry != 0 {
                let (s, c) = out[k].addingReportingOverflow(carry)
                out[k] = s
                carry = c ? 1 : 0
                k += 1
            }
        }
        return BigUInt(limbs: out)
    }

    public func multiplied(bySmall m: UInt64) -> BigUInt {
        guard m != 0, !isZero else { return BigUInt() }
        var out = [UInt64](repeating: 0, count: limbs.count + 1)
        var carry: UInt64 = 0
        for (i, x) in limbs.enumerated() {
            let (hi, lo) = x.multipliedFullWidth(by: m)
            let (s, c) = lo.addingReportingOverflow(carry)
            out[i] = s
            carry = hi &+ (c ? 1 : 0)
        }
        out[limbs.count] = carry
        return BigUInt(limbs: out)
    }

    public func adding(small m: UInt64) -> BigUInt {
        self + BigUInt(m)
    }

    public static func < (a: BigUInt, b: BigUInt) -> Bool {
        if a.limbs.count != b.limbs.count { return a.limbs.count < b.limbs.count }
        for i in stride(from: a.limbs.count - 1, through: 0, by: -1) where a.limbs[i] != b.limbs[i] {
            return a.limbs[i] < b.limbs[i]
        }
        return false
    }

    /// Quotient and remainder (`b` must not be zero): schoolbook long division by limbs when `b` has one limb,
    /// otherwise binary long division.
    public func quotientAndRemainder(dividingBy b: BigUInt) -> (quotient: BigUInt, remainder: BigUInt) {
        precondition(!b.isZero, "division by zero")
        if self < b { return (BigUInt(), self) }
        if b.limbs.count == 1 {
            let d = b.limbs[0]
            var q = [UInt64](repeating: 0, count: limbs.count)
            var r: UInt64 = 0
            for i in stride(from: limbs.count - 1, through: 0, by: -1) {
                let (qi, ri) = d.dividingFullWidth((r, limbs[i]))
                q[i] = qi
                r = ri
            }
            return (BigUInt(limbs: q), BigUInt(r))
        }
        var q = [UInt64](repeating: 0, count: limbs.count)
        var r = BigUInt()
        for i in stride(from: bitLength - 1, through: 0, by: -1) {
            r = r << 1
            if bit(i) { r = r.adding(small: 1) }
            if !(r < b) {
                r = r - b
                q[i / 64] |= UInt64(1) << UInt64(i % 64)
            }
        }
        return (BigUInt(limbs: q), r)
    }

    public static func pow10(_ n: Int) -> BigUInt {
        var r = BigUInt(1)
        var k = n
        while k >= 19 {
            r = r.multiplied(bySmall: 10_000_000_000_000_000_000)
            k -= 19
        }
        var tail: UInt64 = 1
        for _ in 0..<k { tail *= 10 }
        return r.multiplied(bySmall: tail)
    }

    public var description: String {
        if isZero { return "0" }
        var digits: [String] = []
        var v = self
        let chunk = BigUInt(10_000_000_000_000_000_000)
        while !v.isZero {
            let (q, r) = v.quotientAndRemainder(dividingBy: chunk)
            digits.append(String(r.low64))
            v = q
        }
        var s = digits.removeLast()
        for d in digits.reversed() { s += String(repeating: "0", count: 19 - d.count) + d }
        return s
    }
}

/// A fixed-width two's-complement integer (C23 integer types up to `BITINT_MAXWIDTH`): `bits` holds the value
/// modulo 2^width, and signedness belongs to the operation, as in LLVM's `APInt`.
public struct APInt: Sendable, Equatable, Hashable {
    public let width: Int
    /// The value modulo 2^width (no bits at or above `width`).
    public private(set) var bits: BigUInt

    public init(width: Int, bits: BigUInt) {
        self.width = max(1, width)
        self.bits = bits
        truncateToWidth()
    }

    public init(width: Int, value: UInt64) {
        self.init(width: width, bits: BigUInt(value))
    }

    /// `value` sign-extended (or truncated) to `width` bits.
    public init(width: Int, signed value: Int64) {
        if value >= 0 {
            self.init(width: width, value: UInt64(value))
        } else {
            self = APInt(width: width, value: UInt64(-(value + 1))).not()
        }
    }

    private mutating func truncateToWidth() {
        guard bits.bitLength > width else { return }
        var limbs = bits.limbs
        let words = (width + 63) / 64
        limbs.removeLast(limbs.count - words)
        if width % 64 != 0 { limbs[words - 1] &= (UInt64(1) << UInt64(width % 64)) - 1 }
        bits = BigUInt(limbs: limbs)
    }

    public static func zero(width: Int) -> APInt { APInt(width: width, value: 0) }
    public static func allOnes(width: Int) -> APInt { APInt.zero(width: width).not() }

    public var isZero: Bool { bits.isZero }
    public var isNegative: Bool { bits.bit(width - 1) }

    /// The magnitude of the value read as signed.
    public var signedMagnitude: BigUInt { isNegative ? negated().bits : bits }

    /// The low 64 bits.
    public var low64: UInt64 { bits.low64 }

    /// The value as `Int64` (sign-extended from `width` if read as signed), or nil if it does not fit.
    public func int64(signed: Bool) -> Int64? {
        if signed {
            let ext = extended(to: max(width, 64), signed: true)
            let t = ext.truncated(to: 64)
            return t.extended(to: ext.width, signed: true) == ext ? Int64(bitPattern: t.low64) : nil
        }
        return bits.bitLength <= 63 ? Int64(bits.low64) : nil
    }

    public func not() -> APInt {
        let words = (width + 63) / 64
        var limbs = bits.limbs + [UInt64](repeating: 0, count: max(0, words - bits.limbs.count))
        for i in 0..<words { limbs[i] = ~limbs[i] }
        return APInt(width: width, bits: BigUInt(limbs: limbs))
    }

    public func negated() -> APInt { not().adding(APInt(width: width, value: 1)) }

    public func adding(_ o: APInt) -> APInt { APInt(width: width, bits: bits + o.bits) }
    public func subtracting(_ o: APInt) -> APInt { adding(o.negated()) }
    public func multiplied(by o: APInt) -> APInt { APInt(width: width, bits: bits * o.bits) }

    /// Division truncating toward zero; nil when dividing by zero. The overflowing `MIN / -1` wraps, as Clang folds it.
    public func divided(by o: APInt, signed: Bool) -> APInt? {
        guard !o.isZero else { return nil }
        if !signed { return APInt(width: width, bits: bits.quotientAndRemainder(dividingBy: o.bits).quotient) }
        let q = APInt(width: width, bits: signedMagnitude.quotientAndRemainder(dividingBy: o.signedMagnitude).quotient)
        return isNegative != o.isNegative ? q.negated() : q
    }

    /// The remainder with the sign of the dividend; nil when dividing by zero.
    public func remainder(dividingBy o: APInt, signed: Bool) -> APInt? {
        guard !o.isZero else { return nil }
        if !signed { return APInt(width: width, bits: bits.quotientAndRemainder(dividingBy: o.bits).remainder) }
        let r = APInt(width: width, bits: signedMagnitude.quotientAndRemainder(dividingBy: o.signedMagnitude).remainder)
        return isNegative ? r.negated() : r
    }

    public func shiftedLeft(_ n: Int) -> APInt { APInt(width: width, bits: bits << n) }

    public func shiftedRight(_ n: Int, signed: Bool) -> APInt {
        let shifted = APInt(width: width, bits: bits >> n)
        guard signed && isNegative && n > 0 else { return shifted }
        // Fill the vacated high bits with ones
        let fill = n >= width ? APInt.allOnes(width: width) : APInt.allOnes(width: width).shiftedLeft(width - n)
        return shifted.bitOr(fill)
    }

    public func bitAnd(_ o: APInt) -> APInt { zip(o) { $0 & $1 } }
    public func bitOr(_ o: APInt) -> APInt { zip(o) { $0 | $1 } }
    public func bitXor(_ o: APInt) -> APInt { zip(o) { $0 ^ $1 } }

    private func zip(_ o: APInt, _ f: (UInt64, UInt64) -> UInt64) -> APInt {
        let n = max(bits.limbs.count, o.bits.limbs.count)
        var out = [UInt64](repeating: 0, count: n)
        for i in 0..<n {
            out[i] = f(i < bits.limbs.count ? bits.limbs[i] : 0, i < o.bits.limbs.count ? o.bits.limbs[i] : 0)
        }
        return APInt(width: width, bits: BigUInt(limbs: out))
    }

    public func truncated(to w: Int) -> APInt { APInt(width: w, bits: bits) }

    /// Truncation or extension to `w` bits (sign extension if `signed`).
    public func extended(to w: Int, signed: Bool) -> APInt {
        guard w > width, signed, isNegative else { return APInt(width: w, bits: bits) }
        let ones = APInt.allOnes(width: w).shiftedLeft(width)
        return APInt(width: w, bits: bits).bitOr(ones)
    }

    public func compare(_ o: APInt, signed: Bool) -> Int {
        if signed && isNegative != o.isNegative { return isNegative ? -1 : 1 }
        if bits == o.bits { return 0 }
        return bits < o.bits ? -1 : 1
    }

    /// The value's bytes, little-endian, in `size` bytes (truncating or zero/sign-padding per `signed`).
    public func littleEndianBytes(size: Int, signed: Bool) -> [UInt8] {
        let ext = extended(to: max(width, size * 8), signed: signed)
        var out = [UInt8](repeating: 0, count: size)
        for i in 0..<size {
            let limb = i / 8 < ext.bits.limbs.count ? ext.bits.limbs[i / 8] : 0
            out[i] = UInt8(truncatingIfNeeded: limb >> UInt64((i % 8) * 8))
        }
        return out
    }
}
