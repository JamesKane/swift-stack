// Sources/SwiftStack/Lex/CLiteral.swift
// Shared decoding of C23 integer constants, character constants and string-literal escapes
// (C23 6.4.4.1, 6.4.4.5, 6.4.5). Used by the preprocessor (`#if`), semantic analysis and AIR lowering
// so that every stage agrees on a literal's value.

public enum CLiteral {

    /// Value of an integer constant and whether its type is unsigned (`u` suffix, or a value that does
    /// not fit `intmax_t`). Digit separators (`'`) and the `l`/`ll`/`z`/`wb` suffixes are accepted.
    /// Returns nil if the spelling is not a valid integer constant.
    public static func integerValue(_ raw: String) -> (value: UInt64, isUnsigned: Bool)? {
        var s = Substring(raw.filter { $0 != "'" })
        var isUnsigned = false
        while let last = s.last, "uUlLzZ".contains(last) || ((last == "b" || last == "B") && s.dropLast().last.map { "wW".contains($0) } == true) {
            if last == "b" || last == "B" {
                s = s.dropLast(2)  // `wb` / `WB` (_BitInt)
                continue
            }
            if last == "u" || last == "U" { isUnsigned = true }
            s = s.dropLast()
        }
        let lower = s.lowercased()
        let value: UInt64?
        if lower.hasPrefix("0x") {
            value = UInt64(lower.dropFirst(2), radix: 16)
        } else if lower.hasPrefix("0b") {
            value = UInt64(lower.dropFirst(2), radix: 2)
        } else if lower.hasPrefix("0") && lower.count > 1 {
            value = UInt64(lower.dropFirst(1), radix: 8)
        } else {
            value = UInt64(lower, radix: 10)
        }
        guard let v = value else { return nil }
        return (v, isUnsigned || v > UInt64(Int64.max))
    }

    /// Decodes the escape sequences of a literal body (without quotes or encoding prefix) into code-unit
    /// values: simple escapes, octal (`\101`), hexadecimal (`\x41`) and universal names (`é`).
    public static func decodeEscapes<S: StringProtocol>(_ body: S) -> [UInt32] {
        decodeUnits(body).map(\.value)
    }

    /// Decoded units, each flagged if it came from an octal/hex escape (a raw byte value rather than a
    /// character, which matters for narrow strings: `"\351"` is one byte, `"é"` is UTF-8).
    private static func decodeUnits<S: StringProtocol>(_ body: S) -> [(value: UInt32, isByteEscape: Bool)] {
        var out: [(value: UInt32, isByteEscape: Bool)] = []
        let u = Array(body.unicodeScalars)
        var i = 0
        func hexValue(_ c: Unicode.Scalar) -> UInt32? {
            switch c {
            case "0"..."9": return c.value - 0x30
            case "a"..."f": return c.value - 0x61 + 10
            case "A"..."F": return c.value - 0x41 + 10
            default: return nil
            }
        }
        while i < u.count {
            let c = u[i]
            guard c == "\\", i + 1 < u.count else {
                out.append((c.value, false))
                i += 1
                continue
            }
            i += 1
            let e = u[i]
            i += 1
            switch e {
            case "n": out.append((0x0A, false))
            case "t": out.append((0x09, false))
            case "r": out.append((0x0D, false))
            case "a": out.append((0x07, false))
            case "b": out.append((0x08, false))
            case "f": out.append((0x0C, false))
            case "v": out.append((0x0B, false))
            case "e", "E": out.append((0x1B, false))  // GNU extension
            case "0"..."7":
                var v = e.value - 0x30
                var n = 1
                while n < 3, i < u.count, ("0"..."7").contains(u[i]) {
                    v = v * 8 + (u[i].value - 0x30)
                    i += 1
                    n += 1
                }
                out.append((v, true))
            case "x":
                var v: UInt32 = 0
                while i < u.count, let h = hexValue(u[i]) {
                    v = (v &<< 4) | h
                    i += 1
                }
                out.append((v, true))
            case "u", "U":
                let digits = (e == "u") ? 4 : 8
                var v: UInt32 = 0
                var n = 0
                while n < digits, i < u.count, let h = hexValue(u[i]) {
                    v = (v << 4) | h
                    i += 1
                    n += 1
                }
                out.append((v, false))
            default:
                out.append((e.value, false))  // `\\`, `\'`, `\"`, `\?`
            }
        }
        return out
    }

    /// Strips an encoding prefix (`u8`, `u`, `U`, `L`) and the surrounding quotes from a literal spelling.
    public static func body(of raw: String, quote: Character) -> Substring {
        guard let first = raw.firstIndex(of: quote), let last = raw.lastIndex(of: quote), first < last else {
            return Substring(raw)
        }
        return raw[raw.index(after: first)..<last]
    }

    /// Value of a character constant (C23 6.4.4.5). A plain single-byte constant has type `int` with the
    /// value of a `char` (signed on x86-64, unsigned on AArch64 and RISC-V: `charIsSigned`); a multi-character
    /// constant combines its bytes big-endian, as GCC and Clang do. Prefixed constants (`u'x'`, `L'x'`) are unsigned.
    public static func characterValue(_ raw: String, charIsSigned: Bool = true) -> Int64 {
        let units = decodeEscapes(body(of: raw, quote: "'"))
        let isPrefixed = !raw.hasPrefix("'")
        guard let first = units.first else { return 0 }
        if isPrefixed { return Int64(units.last ?? first) }
        if units.count == 1 {
            guard first <= 0xFF else { return Int64(first) }
            return charIsSigned ? Int64(Int8(truncatingIfNeeded: first)) : Int64(first)
        }
        var v: Int64 = 0
        for unit in units { v = (v << 8) | Int64(unit & 0xFF) }
        return Int64(Int32(truncatingIfNeeded: v))
    }

    /// Bytes of a narrow string literal's body after escape decoding: octal/hex escapes give one byte each,
    /// characters and universal character names are UTF-8 encoded.
    public static func stringBytes<S: StringProtocol>(_ body: S) -> [UInt8] {
        var out: [UInt8] = []
        for unit in decodeUnits(body) {
            if unit.isByteEscape || unit.value < 0x80 {
                out.append(UInt8(truncatingIfNeeded: unit.value))
            } else if let scalar = Unicode.Scalar(unit.value) {
                out.append(contentsOf: Array(String(Character(scalar)).utf8))
            }
        }
        return out
    }

    /// Code units of a string literal's body (C23 6.4.5p5) of `unitSize` bytes: UTF-8 bytes (as `stringBytes`), UTF-16
    /// code units (a character above U+FFFF is a surrogate pair), or UTF-32 code points. An octal or hexadecimal
    /// escape is one code unit, truncated to the unit's width.
    public static func codeUnits<S: StringProtocol>(_ body: S, unitSize: Int) -> [UInt32] {
        if unitSize == 1 { return stringBytes(body).map { UInt32($0) } }
        var out: [UInt32] = []
        for unit in decodeUnits(body) {
            if unit.isByteEscape || unitSize == 4 {
                out.append(unitSize == 2 ? unit.value & 0xFFFF : unit.value)
            } else if let scalar = Unicode.Scalar(unit.value) {
                out.append(contentsOf: String(Character(scalar)).utf16.map { UInt32($0) })
            }
        }
        return out
    }

    /// String form of `stringBytes` used as a string-table key by semantic analysis and AIR lowering.
    public static func unescapedString<S: StringProtocol>(_ body: S) -> String {
        String(decoding: stringBytes(body), as: UTF8.self)
    }
}
