// Sources/SwiftStack/Lex/CLexer.swift

/// High-throughput ISO C23 lexical analyzer with SWAR scanning and @_noAllocation inner loop (01-frontend.md §4.4-4.5).
public struct CLexer: ~Copyable {
    public let fileId: FileId
    public let baseLocation: SourceLocation
    public let startPtr: UnsafePointer<UInt8>
    public let endPtr: UnsafePointer<UInt8>

    public init(fileId: FileId, buffer: UnsafeBufferPointer<UInt8>, length: Int? = nil, baseLocation: SourceLocation = .zero) {
        self.fileId = fileId
        self.baseLocation = baseLocation
        guard let base = buffer.baseAddress else {
            let dummy = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
            dummy.initialize(repeating: 0, count: 64)
            self.startPtr = UnsafePointer(dummy)
            self.endPtr = self.startPtr
            return
        }
        self.startPtr = base
        let fileLength = length ?? buffer.count
        self.endPtr = base + fileLength
    }

    /// Lexes the entire C source buffer into a TokenBuffer.
    public func lexInto(_ tokenBuffer: inout TokenBuffer) {
        let maxTokens = max(1024, (endPtr - startPtr) + 16)
        let neededCap = Int(tokenBuffer.kinds.count) + maxTokens
        tokenBuffer.reserveCapacity(neededCap)

        var count = Int(tokenBuffer.kinds.count)
        let maxCap = tokenBuffer.capacity

        tokenBuffer.kinds.withCommittedBufferPointer { kBuf in
            tokenBuffer.flags.withCommittedBufferPointer { fBuf in
                tokenBuffer.starts.withCommittedBufferPointer { sBuf in
                    tokenBuffer.ends.withCommittedBufferPointer { eBuf in
                        Self.lexInnerLoop(
                            start: startPtr,
                            end: endPtr,
                            baseLoc: baseLocation.rawValue,
                            kinds: kBuf.baseAddress!,
                            flags: fBuf.baseAddress!,
                            starts: sBuf.baseAddress!,
                            ends: eBuf.baseAddress!,
                            count: &count,
                            capacity: maxCap
                        )
                    }
                }
            }
        }

        tokenBuffer.kinds.setCount(UInt32(count))
        tokenBuffer.flags.setCount(UInt32(count))
        tokenBuffer.starts.setCount(UInt32(count))
        tokenBuffer.ends.setCount(UInt32(count))
    }

    /// Inner C lexing loop marked @_noAllocation (Principle 8).
    @_noAllocation
    public static func lexInnerLoop(
        start: UnsafePointer<UInt8>,
        end: UnsafePointer<UInt8>,
        baseLoc: UInt32,
        kinds: UnsafeMutablePointer<UInt8>,
        flags: UnsafeMutablePointer<UInt8>,
        starts: UnsafeMutablePointer<UInt32>,
        ends: UnsafeMutablePointer<UInt32>,
        count: inout Int,
        capacity: Int
    ) {
        let flagLeadingSpace: UInt8   = 1 << 0
        let flagLeadingNewline: UInt8 = 1 << 1
        let flagTrailingSpace: UInt8  = 1 << 2
        let flagHasError: UInt8       = 1 << 7

        var cursor = start
        var hasLeadingSpace = false
        var hasLeadingNewline = false

        while cursor < end {
            let b = cursor.pointee

            // Whitespace
            if b == 0x20 || b == 0x09 {
                hasLeadingSpace = true
                cursor += 1
                while cursor + 8 <= end {
                    let w = UnsafeRawPointer(cursor).loadUnaligned(as: UInt64.self)
                    let run = SWAR.horizontalSpaceRun(w)
                    cursor += run
                    if run < 8 { break }
                }
                continue
            }
            if b == 0x0A {
                hasLeadingNewline = true
                hasLeadingSpace = false
                cursor += 1
                continue
            }
            if b == 0x0D {
                hasLeadingNewline = true
                hasLeadingSpace = false
                cursor += 1
                if cursor < end && cursor.pointee == 0x0A {
                    cursor += 1
                }
                continue
            }

            // Comments
            if b == 0x2F && cursor + 1 < end {
                let next = cursor[1]
                if next == 0x2F { // line comment
                    hasLeadingSpace = true
                    cursor += 2
                    while cursor < end && cursor.pointee != 0x0A && cursor.pointee != 0x0D {
                        cursor += 1
                    }
                    continue
                } else if next == 0x2A { // block comment
                    hasLeadingSpace = true
                    cursor += 2
                    while cursor < end {
                        if cursor.pointee == 0x2A && cursor + 1 < end && cursor[1] == 0x2F {
                            cursor += 2
                            break
                        }
                        if cursor.pointee == 0x0A {
                            hasLeadingNewline = true
                        }
                        cursor += 1
                    }
                    continue
                }
            }

            let tokenStart = cursor
            let startOffset = baseLoc + UInt32(tokenStart - start)
            var tokenKind: UInt8 = 0
            var tokenFlag: UInt8 = 0
            if hasLeadingSpace { tokenFlag |= flagLeadingSpace }
            if hasLeadingNewline { tokenFlag |= flagLeadingNewline }

            let charClass = CharacterTable.classify(b)

            switch charClass {
            case .identStart:
                cursor += 1
                while cursor + 8 <= end {
                    let w = UnsafeRawPointer(cursor).loadUnaligned(as: UInt64.self)
                    guard let run = SWAR.identifierRun(w) else { break }
                    cursor += run
                    if run < 8 { break }
                }
                while cursor < end {
                    let c = cursor.pointee
                    if (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39) || c == 0x5F {
                        cursor += 1
                    } else {
                        break
                    }
                }
                let len = cursor - tokenStart
                tokenKind = matchCKeyword(ptr: tokenStart, length: len)

            case .digit:
                cursor += 1
                if b == 0x30 /* '0' */ && cursor < end {
                    let next = cursor.pointee
                    if next == 0x78 /* 'x' */ || next == 0x58 /* 'X' */ || next == 0x62 /* 'b' */ || next == 0x42 /* 'B' */ {
                        cursor += 1
                    }
                }
                while cursor < end {
                    let c = cursor.pointee
                    if (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || c == 0x27 /* '\'' */ {
                        cursor += 1
                    } else {
                        break
                    }
                }
                if cursor + 1 < end && cursor.pointee == 0x2E /* '.' */ && cursor[1] >= 0x30 && cursor[1] <= 0x39 {
                    tokenKind = 3 // floatLiteral
                    cursor += 2
                    while cursor < end && ((cursor.pointee >= 0x30 && cursor.pointee <= 0x39) || cursor.pointee == 0x27) {
                        cursor += 1
                    }
                } else {
                    tokenKind = 2 // intLiteral
                }

            case .quote:
                cursor += 1
                var escaped = false
                while cursor < end {
                    let c = cursor.pointee
                    if escaped {
                        escaped = false
                        cursor += 1
                    } else if c == 0x5C /* '\\' */ {
                        escaped = true
                        cursor += 1
                    } else if c == 0x22 /* '"' */ {
                        cursor += 1
                        break
                    } else if c == 0x0A || c == 0x0D {
                        tokenFlag |= flagHasError
                        break
                    } else {
                        cursor += 1
                    }
                }
                tokenKind = 5 // stringLiteral

            case .singleQuote:
                cursor += 1
                var escaped = false
                while cursor < end {
                    let c = cursor.pointee
                    if escaped {
                        escaped = false
                        cursor += 1
                    } else if c == 0x5C {
                        escaped = true
                        cursor += 1
                    } else if c == 0x27 {
                        cursor += 1
                        break
                    } else if c == 0x0A || c == 0x0D {
                        tokenFlag |= flagHasError
                        break
                    } else {
                        cursor += 1
                    }
                }
                tokenKind = 4 // charLiteral

            case .lParen:
                cursor += 1
                tokenKind = 60
            case .rParen:
                cursor += 1
                tokenKind = 61
            case .lBrace:
                cursor += 1
                tokenKind = 62
            case .rBrace:
                cursor += 1
                tokenKind = 63
            case .lBracket:
                cursor += 1
                tokenKind = 64
            case .rBracket:
                cursor += 1
                tokenKind = 65
            case .semicolon:
                cursor += 1
                tokenKind = 66
            case .comma:
                cursor += 1
                tokenKind = 67
            case .colon:
                cursor += 1
                tokenKind = 68

            case .period:
                cursor += 1
                if cursor + 1 < end && cursor.pointee == 0x2E && cursor[1] == 0x2E {
                    cursor += 2
                    tokenKind = 95 // ellipsis
                } else {
                    tokenKind = 69 // period
                }

            case .pound:
                cursor += 1
                if cursor < end && cursor.pointee == 0x23 {
                    cursor += 1
                    tokenKind = 97 // hashHash
                } else {
                    tokenKind = 96 // hash
                }

            case .slash:
                cursor += 1
                tokenKind = 74 // slash

            case .operatorChar:
                let op = b
                cursor += 1
                let next = cursor < end ? cursor.pointee : 0

                switch op {
                case 0x2B: // '+'
                    if next == 0x2B { cursor += 1; tokenKind = 84 }
                    else { tokenKind = 71 }
                case 0x2D: // '-'
                    if next == 0x2D { cursor += 1; tokenKind = 85 }
                    else if next == 0x3E { cursor += 1; tokenKind = 70 }
                    else { tokenKind = 72 }
                case 0x2A: // '*'
                    tokenKind = 73
                case 0x25: // '%'
                    tokenKind = 75
                case 0x26: // '&'
                    if next == 0x26 { cursor += 1; tokenKind = 92 }
                    else { tokenKind = 76 }
                case 0x7C: // '|'
                    if next == 0x7C { cursor += 1; tokenKind = 93 }
                    else { tokenKind = 77 }
                case 0x5E: // '^'
                    tokenKind = 78
                case 0x21: // '!'
                    if next == 0x3D { cursor += 1; tokenKind = 91 }
                    else { tokenKind = 80 }
                case 0x3D: // '='
                    if next == 0x3D { cursor += 1; tokenKind = 90 }
                    else { tokenKind = 81 }
                case 0x3C: // '<'
                    if next == 0x3C { cursor += 1; tokenKind = 86 }
                    else if next == 0x3D { cursor += 1; tokenKind = 88 }
                    else { tokenKind = 82 }
                case 0x3E: // '>'
                    if next == 0x3E { cursor += 1; tokenKind = 87 }
                    else if next == 0x3D { cursor += 1; tokenKind = 89 }
                    else { tokenKind = 83 }
                case 0x7E: // '~'
                    tokenKind = 79
                case 0x3F: // '?'
                    tokenKind = 94
                default:
                    tokenKind = 255
                }

            case .nul:
                if cursor >= end { break }
                tokenFlag |= flagHasError
                tokenKind = 255
                cursor += 1

            default:
                cursor += 1
                tokenFlag |= flagHasError
                tokenKind = 255
            }

            var hasTrailingSpace = false
            if cursor < end {
                let nextB = cursor.pointee
                if nextB == 0x20 || nextB == 0x09 || nextB == 0x0A || nextB == 0x0D {
                    hasTrailingSpace = true
                }
            } else {
                hasTrailingSpace = true
            }
            if hasTrailingSpace {
                tokenFlag |= flagTrailingSpace
            }

            if count < capacity {
                kinds[count] = tokenKind
                flags[count] = tokenFlag
                starts[count] = startOffset
                ends[count] = baseLoc + UInt32(cursor - start)
                count += 1
            }

            hasLeadingSpace = false
            hasLeadingNewline = false
        }

        if count < capacity {
            kinds[count] = 254 // eof
            flags[count] = flagTrailingSpace
            starts[count] = baseLoc + UInt32(end - start)
            ends[count] = baseLoc + UInt32(end - start)
            count += 1
        }
    }

    /// Fast C23 keyword matcher returning raw TokenKind byte.
    @_noAllocation
    @inline(__always)
    public static func matchCKeyword(ptr: UnsafePointer<UInt8>, length: Int) -> UInt8 {
        switch length {
        case 2:
            if ptr[0] == 0x64 && ptr[1] == 0x6F { return 17 } // do
            if ptr[0] == 0x69 && ptr[1] == 0x66 { return 25 } // if
        case 3:
            if ptr[0] == 0x66 && ptr[1] == 0x6F && ptr[2] == 0x72 { return 23 } // for
            if ptr[0] == 0x69 && ptr[1] == 0x6E && ptr[2] == 0x74 { return 27 } // int
        case 4:
            let w = UnsafeRawPointer(ptr).loadUnaligned(as: UInt32.self)
            if w == 0x6f747561 { return 10 } // auto
            if w == 0x72616863 { return 13 } // char
            if w == 0x65736c65 { return 19 } // else
            if w == 0x6d756e65 { return 20 } // enum
            if w == 0x6f746f67 { return 24 } // goto
            if w == 0x676e6f6c { return 28 } // long
            if w == 0x64696f76 { return 41 } // void
            if w == 0x65757274 { return 50 } // true
            if w == 0x6c6f6f62 { return 47 } // bool
            if w == 0x65736163 { return 12 } // case
        case 5:
            if ptr[0] == 0x62 && ptr[1] == 0x72 && ptr[2] == 0x65 && ptr[3] == 0x61 && ptr[4] == 0x6B { return 11 } // break
            if ptr[0] == 0x63 && ptr[1] == 0x6F && ptr[2] == 0x6E && ptr[3] == 0x73 && ptr[4] == 0x74 { return 14 } // const
            if ptr[0] == 0x66 && ptr[1] == 0x6C && ptr[2] == 0x6F && ptr[3] == 0x61 && ptr[4] == 0x74 { return 22 } // float
            if ptr[0] == 0x73 && ptr[1] == 0x68 && ptr[2] == 0x6F && ptr[3] == 0x72 && ptr[4] == 0x74 { return 32 } // short
            if ptr[0] == 0x75 && ptr[1] == 0x6E && ptr[2] == 0x69 && ptr[3] == 0x6F && ptr[4] == 0x6E { return 39 } // union
            if ptr[0] == 0x77 && ptr[1] == 0x68 && ptr[2] == 0x69 && ptr[3] == 0x6C && ptr[4] == 0x65 { return 43 } // while
            if ptr[0] == 0x66 && ptr[1] == 0x61 && ptr[2] == 0x6C && ptr[3] == 0x73 && ptr[4] == 0x65 { return 49 } // false
        case 6:
            if ptr[0] == 0x64 && ptr[1] == 0x6F && ptr[2] == 0x75 && ptr[3] == 0x62 && ptr[4] == 0x6C && ptr[5] == 0x65 { return 18 } // double
            if ptr[0] == 0x65 && ptr[1] == 0x78 && ptr[2] == 0x74 && ptr[3] == 0x65 && ptr[4] == 0x72 && ptr[5] == 0x6E { return 21 } // extern
            if ptr[0] == 0x69 && ptr[1] == 0x6E && ptr[2] == 0x6C && ptr[3] == 0x69 && ptr[4] == 0x6E && ptr[5] == 0x65 { return 26 } // inline
            if ptr[0] == 0x72 && ptr[1] == 0x65 && ptr[2] == 0x74 && ptr[3] == 0x75 && ptr[4] == 0x72 && ptr[5] == 0x6E { return 31 } // return
            if ptr[0] == 0x73 && ptr[1] == 0x69 && ptr[2] == 0x67 && ptr[3] == 0x6E && ptr[4] == 0x65 && ptr[5] == 0x64 { return 33 } // signed
            if ptr[0] == 0x73 && ptr[1] == 0x69 && ptr[2] == 0x7A && ptr[3] == 0x65 && ptr[4] == 0x6F && ptr[5] == 0x66 { return 34 } // sizeof
            if ptr[0] == 0x73 && ptr[1] == 0x74 && ptr[2] == 0x61 && ptr[3] == 0x74 && ptr[4] == 0x69 && ptr[5] == 0x63 { return 35 } // static
            if ptr[0] == 0x73 && ptr[1] == 0x74 && ptr[2] == 0x72 && ptr[3] == 0x75 && ptr[4] == 0x63 && ptr[5] == 0x74 { return 36 } // struct
            if ptr[0] == 0x73 && ptr[1] == 0x77 && ptr[2] == 0x69 && ptr[3] == 0x74 && ptr[4] == 0x63 && ptr[5] == 0x68 { return 37 } // switch
            if ptr[0] == 0x74 && ptr[1] == 0x79 && ptr[2] == 0x70 && ptr[3] == 0x65 && ptr[4] == 0x6F && ptr[5] == 0x66 { return 54 } // typeof
        case 7:
            if ptr[0] == 0x64 && ptr[1] == 0x65 && ptr[2] == 0x66 && ptr[3] == 0x61 && ptr[4] == 0x75 && ptr[5] == 0x6C && ptr[6] == 0x74 { return 16 } // default
            if ptr[0] == 0x74 && ptr[1] == 0x79 && ptr[2] == 0x70 && ptr[3] == 0x65 && ptr[4] == 0x64 && ptr[5] == 0x65 && ptr[6] == 0x66 { return 38 } // typedef
            if ptr[0] == 0x6E && ptr[1] == 0x75 && ptr[2] == 0x6C && ptr[3] == 0x6C && ptr[4] == 0x70 && ptr[5] == 0x74 && ptr[6] == 0x72 { return 51 } // nullptr
            if ptr[0] == 0x61 && ptr[1] == 0x6C && ptr[2] == 0x69 && ptr[3] == 0x67 && ptr[4] == 0x6E && ptr[5] == 0x61 && ptr[6] == 0x73 { return 44 } // alignas
            if ptr[0] == 0x61 && ptr[1] == 0x6C && ptr[2] == 0x69 && ptr[3] == 0x67 && ptr[4] == 0x6E && ptr[5] == 0x6F && ptr[6] == 0x66 { return 45 } // alignof
        case 8:
            if ptr[0] == 0x63 && ptr[1] == 0x6F && ptr[2] == 0x6E && ptr[3] == 0x74 && ptr[4] == 0x69 && ptr[5] == 0x6E && ptr[6] == 0x75 && ptr[7] == 0x65 { return 15 } // continue
            if ptr[0] == 0x72 && ptr[1] == 0x65 && ptr[2] == 0x67 && ptr[3] == 0x69 && ptr[4] == 0x73 && ptr[5] == 0x74 && ptr[6] == 0x65 && ptr[7] == 0x72 { return 29 } // register
            if ptr[0] == 0x72 && ptr[1] == 0x65 && ptr[2] == 0x73 && ptr[3] == 0x74 && ptr[4] == 0x72 && ptr[5] == 0x69 && ptr[6] == 0x63 && ptr[7] == 0x74 { return 30 } // restrict
            if ptr[0] == 0x75 && ptr[1] == 0x6E && ptr[2] == 0x73 && ptr[3] == 0x69 && ptr[4] == 0x67 && ptr[5] == 0x6E && ptr[6] == 0x65 && ptr[7] == 0x64 { return 40 } // unsigned
            if ptr[0] == 0x76 && ptr[1] == 0x6F && ptr[2] == 0x6C && ptr[3] == 0x61 && ptr[4] == 0x74 && ptr[5] == 0x69 && ptr[6] == 0x6C && ptr[7] == 0x65 { return 42 } // volatile
        case 9:
            if ptr[0] == 0x63 && ptr[1] == 0x6F && ptr[2] == 0x6E && ptr[3] == 0x73 && ptr[4] == 0x74 && ptr[5] == 0x65 && ptr[6] == 0x78 && ptr[7] == 0x70 && ptr[8] == 0x72 { return 48 } // constexpr
        case 13:
            if ptr[0] == 0x73 && ptr[1] == 0x74 && ptr[2] == 0x61 && ptr[3] == 0x74 && ptr[4] == 0x69 && ptr[5] == 0x63 && ptr[6] == 0x5F &&
               ptr[7] == 0x61 && ptr[8] == 0x73 && ptr[9] == 0x73 && ptr[10] == 0x65 && ptr[11] == 0x72 && ptr[12] == 0x74 {
                return 52 // static_assert
            }
        default:
            break
        }
        return 1 // identifier
    }
}
