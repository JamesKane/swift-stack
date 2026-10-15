// Sources/SwiftStack/Lex/SWAR.swift

/// SIMD-Within-A-Register (SWAR) bit-manipulation primitives for 8-byte bulk scanning (01-frontend.md §4.4).
public enum SWAR {
    @usableFromInline
    static let hiBits: UInt64 = 0x8080_8080_8080_8080
    @usableFromInline
    static let loBits: UInt64 = 0x0101_0101_0101_0101

    /// Broadcasts an 8-bit byte value across all 8 bytes of a 64-bit word.
    @_noAllocation
    @inline(__always)
    public static func bcast(_ b: UInt8) -> UInt64 {
        loBits &* UInt64(b)
    }

    /// Sets the high bit of each byte where lo <= byte <= hi.
    /// Precondition: every byte in w is < 0x80 (pure ASCII).
    @_noAllocation
    @inline(__always)
    public static func inRange(_ w: UInt64, _ lo: UInt8, _ hi: UInt8) -> UInt64 {
        let ge = ((w | hiBits) &- bcast(lo)) & hiBits
        let le = ((bcast(hi) | hiBits) &- w) & hiBits
        return ge & le
    }

    /// Sets the high bit of exactly those bytes of w that are zero.
    ///
    /// The shorter `(w - 0x01..) & ~w & 0x80..` only answers "is there any zero byte": its borrow also
    /// flags a 0x01 byte above a zero byte, which made `horizontalSpaceRun` treat the `!` of `  !=` as a
    /// space (`' ' ^ ' ' == 0`, `'!' ^ ' ' == 1`). This form cannot carry or borrow between bytes.
    @_noAllocation
    @inline(__always)
    public static func hasZeroByte(_ w: UInt64) -> UInt64 {
        let lo7: UInt64 = 0x7F7F_7F7F_7F7F_7F7F
        return ~(((w & lo7) &+ lo7) | w | lo7)
    }

    /// Number of leading ASCII identifier-continuation bytes in w (0...8), or nil for non-ASCII.
    /// Matches [a-zA-Z0-9_].
    @_noAllocation
    @inline(__always)
    public static func identifierRun(_ w: UInt64) -> Int? {
        guard w & hiBits == 0 else { return nil } // UTF-8 lead byte -> slow path
        let ident = inRange(w, 0x61, 0x7A) | inRange(w, 0x41, 0x5A)
                  | inRange(w, 0x30, 0x39) | inRange(w, 0x5F, 0x5F)
        let stop = ~ident & hiBits
        return stop == 0 ? 8 : stop.trailingZeroBitCount / 8
    }

    /// Number of leading decimal digits [0-9] in w (0...8), or nil for non-ASCII.
    @_noAllocation
    @inline(__always)
    public static func digitRun(_ w: UInt64) -> Int? {
        guard w & hiBits == 0 else { return nil }
        let digits = inRange(w, 0x30, 0x39)
        let stop = ~digits & hiBits
        return stop == 0 ? 8 : stop.trailingZeroBitCount / 8
    }

    /// Number of leading horizontal whitespace bytes (' ' or '\t') in w (0...8).
    @_noAllocation
    @inline(__always)
    public static func horizontalSpaceRun(_ w: UInt64) -> Int {
        guard w & hiBits == 0 else { return 0 }
        let isSpace = hasZeroByte(w ^ 0x2020_2020_2020_2020)
        let isTab = hasZeroByte(w ^ 0x0909_0909_0909_0909)
        let matched = isSpace | isTab
        let stop = ~matched & hiBits
        return stop == 0 ? 8 : stop.trailingZeroBitCount / 8
    }
}
