// Sources/SwiftStack/Lex/SwiftLexer.swift

/// High-throughput Swift lexical analyzer with SWAR scanning and @_noAllocation inner loop (01-frontend.md §4.4).
public struct SwiftLexer: ~Copyable {
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

    /// Lexes the entire source buffer into a TokenBuffer.
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

    @_noAllocation
    @inline(__always)
    public static func isOperatorOrSlash(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x2B, 0x2D, 0x2A, 0x25, 0x3C, 0x3E, 0x3D, 0x21, 0x26, 0x7C, 0x5E, 0x7E, 0x3F, 0x2F:
            return true
        default:
            return false
        }
    }

    /// Inner lexing loop marked @_noAllocation (Principle 8).
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
        let flagFixityBinary: UInt8   = 1 << 3
        let flagFixityPrefix: UInt8   = 2 << 3
        let flagFixityPostfix: UInt8  = 3 << 3
        let flagHasError: UInt8       = 1 << 7

        var cursor = start
        var hasLeadingSpace = false
        var hasLeadingNewline = false

        while cursor < end {
            // Skip whitespace & trivia
            let b = cursor.pointee
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

            // Check comments
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
                    var depth = 1
                    while cursor < end && depth > 0 {
                        if cursor.pointee == 0x2F && cursor + 1 < end && cursor[1] == 0x2A {
                            depth += 1
                            cursor += 2
                        } else if cursor.pointee == 0x2A && cursor + 1 < end && cursor[1] == 0x2F {
                            depth -= 1
                            cursor += 2
                        } else {
                            if cursor.pointee == 0x0A {
                                hasLeadingNewline = true
                            }
                            cursor += 1
                        }
                    }
                    if depth > 0 {
                        // Unterminated block comment at EOF
                        let tokenStart = cursor
                        let startOffset = baseLoc + UInt32(tokenStart - start)
                        var tokenFlag: UInt8 = flagHasError
                        if hasLeadingSpace { tokenFlag |= flagLeadingSpace }
                        if hasLeadingNewline { tokenFlag |= flagLeadingNewline }
                        if count < capacity {
                            kinds[count] = 255 // errorToken
                            flags[count] = tokenFlag
                            starts[count] = startOffset
                            ends[count] = startOffset
                            count += 1
                        }
                        break
                    }
                    continue
                }
            }

            // At token start
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
                tokenKind = matchSwiftKeyword(ptr: tokenStart, length: len)

            case .dollar:
                cursor += 1
                while cursor < end && ((cursor.pointee >= 0x30 && cursor.pointee <= 0x39) ||
                                       (cursor.pointee >= 0x61 && cursor.pointee <= 0x7A) ||
                                       (cursor.pointee >= 0x41 && cursor.pointee <= 0x5A) ||
                                       cursor.pointee == 0x5F) {
                    cursor += 1
                }
                tokenKind = 2 // dollarIdentifier

            case .digit:
                cursor += 1
                if b == 0x30 /* '0' */ && cursor < end {
                    let next = cursor.pointee
                    if next == 0x78 /* 'x' */ || next == 0x62 /* 'b' */ || next == 0x6F /* 'o' */ {
                        cursor += 1
                    }
                }
                while cursor < end {
                    let c = cursor.pointee
                    if (c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || c == 0x5F {
                        cursor += 1
                    } else {
                        break
                    }
                }
                if cursor + 1 < end && cursor.pointee == 0x2E /* '.' */ && cursor[1] >= 0x30 && cursor[1] <= 0x39 {
                    tokenKind = 4 // floatingLiteral
                    cursor += 2
                    while cursor < end && ((cursor.pointee >= 0x30 && cursor.pointee <= 0x39) || cursor.pointee == 0x5F) {
                        cursor += 1
                    }
                } else {
                    tokenKind = 3 // integerLiteral
                }

            case .quote:
                cursor += 1
                var escaped = false
                var closed = false
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
                        closed = true
                        break
                    } else if c == 0x0A || c == 0x0D {
                        tokenFlag |= flagHasError
                        break
                    } else {
                        cursor += 1
                    }
                }
                if !closed {
                    tokenFlag |= flagHasError
                    tokenKind = 255 // errorToken
                } else {
                    tokenKind = 5 // stringLiteral
                }

            case .lParen:
                cursor += 1
                tokenKind = 70 // lParen
            case .rParen:
                cursor += 1
                tokenKind = 71 // rParen
            case .lBrace:
                cursor += 1
                tokenKind = 72 // lBrace
            case .rBrace:
                cursor += 1
                tokenKind = 73 // rBrace
            case .lBracket:
                cursor += 1
                tokenKind = 74 // lBracket
            case .rBracket:
                cursor += 1
                tokenKind = 75 // rBracket
            case .semicolon:
                cursor += 1
                tokenKind = 79 // semicolon
            case .comma:
                cursor += 1
                tokenKind = 77 // comma
            case .colon:
                cursor += 1
                tokenKind = 78 // colon
            case .at:
                cursor += 1
                tokenKind = 82 // at
            case .pound:
                cursor += 1
                tokenKind = 83 // pound

            case .period:
                cursor += 1
                if cursor < end && cursor.pointee == 0x2E {
                    while cursor < end && cursor.pointee == 0x2E {
                        cursor += 1
                    }
                    tokenKind = 86 // binaryOperator
                } else {
                    tokenKind = 76 // period
                }

            case .operatorChar, .slash:
                cursor += 1
                while cursor < end {
                    let c = cursor.pointee
                    if isOperatorOrSlash(c) {
                        cursor += 1
                    } else {
                        break
                    }
                }
                let opLen = cursor - tokenStart
                if opLen == 1 && tokenStart.pointee == 0x3D /* '=' */ {
                    tokenKind = 81 // equal
                } else if opLen == 2 && tokenStart.pointee == 0x2D && tokenStart[1] == 0x3E /* '->' */ {
                    tokenKind = 80 // arrow
                } else if opLen == 1 && tokenStart.pointee == 0x3F /* '?' */ {
                    tokenKind = 84 // question
                } else if opLen == 1 && tokenStart.pointee == 0x21 /* '!' */ {
                    tokenKind = 85 // exclamation
                } else {
                    tokenKind = 86 // binaryOperator
                }

            case .nul:
                if cursor >= end {
                    break
                }
                tokenFlag |= flagHasError
                tokenKind = 255 // errorToken
                cursor += 1

            default:
                cursor += 1
                tokenFlag |= flagHasError
                tokenKind = 255 // errorToken
            }

            // Check trailing whitespace
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

            // Operator fixity
            if tokenKind == 86 /* binaryOperator */ || tokenKind == 81 /* equal */ || tokenKind == 84 /* question */ || tokenKind == 85 /* exclamation */ {
                let leftBound = !hasLeadingSpace
                let rightBound = !hasTrailingSpace
                if leftBound && !rightBound {
                    tokenFlag |= flagFixityPostfix
                } else if rightBound && !leftBound {
                    tokenFlag |= flagFixityPrefix
                } else {
                    tokenFlag |= flagFixityBinary
                }
            }

            // Emit token
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

        // EOF Token
        if count < capacity {
            kinds[count] = 254 // eof
            flags[count] = flagTrailingSpace
            starts[count] = baseLoc + UInt32(end - start)
            ends[count] = baseLoc + UInt32(end - start)
            count += 1
        }
    }

    /// Fast keyword matcher returning raw TokenKind byte.
    @_noAllocation
    @inline(__always)
    public static func matchSwiftKeyword(ptr: UnsafePointer<UInt8>, length: Int) -> UInt8 {
        switch length {
        case 2:
            if ptr[0] == 0x69 { // 'i'
                if ptr[1] == 0x66 { return 13 } // if
                if ptr[1] == 0x6E { return 17 } // in
                if ptr[1] == 0x73 { return 43 } // is
            } else if ptr[0] == 0x61 && ptr[1] == 0x73 { // as
                return 42
            } else if ptr[0] == 0x64 && ptr[1] == 0x6F { // do
                return 41
            }
        case 3:
            let c0 = ptr[0], c1 = ptr[1], c2 = ptr[2]
            if c0 == 0x6C && c1 == 0x65 && c2 == 0x74 { return 11 } // let
            if c0 == 0x76 && c1 == 0x61 && c2 == 0x72 { return 12 } // var
            if c0 == 0x66 && c1 == 0x6F && c2 == 0x72 { return 16 } // for
            if c0 == 0x6E && c1 == 0x69 && c2 == 0x6C { return 44 } // nil
            if c0 == 0x74 && c1 == 0x72 && c2 == 0x79 { return 39 } // try
        case 4:
            let w = UnsafeRawPointer(ptr).loadUnaligned(as: UInt32.self)
            if w == 0x636e7566 { return 10 } // func
            if w == 0x65736c65 { return 14 } // else
            if w == 0x65736163 { return 31 } // case
            if w == 0x65757274 { return 45 } // true
            if w == 0x666c6573 { return 47 } // self
            if w == 0x666c6553 { return 48 } // Self
            if w == 0x74696e69 { return 24 } // init
            if w == 0x6d756e65 { return 21 } // enum
        case 5:
            if ptr[0] == 0x77 && ptr[1] == 0x68 && ptr[2] == 0x69 && ptr[3] == 0x6C && ptr[4] == 0x65 { return 15 } // while
            if ptr[0] == 0x62 && ptr[1] == 0x72 && ptr[2] == 0x65 && ptr[3] == 0x61 && ptr[4] == 0x6B { return 33 } // break
            if ptr[0] == 0x63 && ptr[1] == 0x6C && ptr[2] == 0x61 && ptr[3] == 0x73 && ptr[4] == 0x73 { return 20 } // class
            if ptr[0] == 0x67 && ptr[1] == 0x75 && ptr[2] == 0x61 && ptr[3] == 0x72 && ptr[4] == 0x64 { return 28 } // guard
            if ptr[0] == 0x64 && ptr[1] == 0x65 && ptr[2] == 0x66 && ptr[3] == 0x65 && ptr[4] == 0x72 { return 29 } // defer
            if ptr[0] == 0x74 && ptr[1] == 0x68 && ptr[2] == 0x72 && ptr[3] == 0x6F && ptr[4] == 0x77 { return 36 } // throw
            if ptr[0] == 0x63 && ptr[1] == 0x61 && ptr[2] == 0x74 && ptr[3] == 0x63 && ptr[4] == 0x68 { return 40 } // catch
            if ptr[0] == 0x66 && ptr[1] == 0x61 && ptr[2] == 0x6C && ptr[3] == 0x73 && ptr[4] == 0x65 { return 46 } // false
            if ptr[0] == 0x73 && ptr[1] == 0x75 && ptr[2] == 0x70 && ptr[3] == 0x65 && ptr[4] == 0x72 { return 49 } // super
            if ptr[0] == 0x77 && ptr[1] == 0x68 && ptr[2] == 0x65 && ptr[3] == 0x72 && ptr[4] == 0x65 { return 51 } // where
            if ptr[0] == 0x6D && ptr[1] == 0x61 && ptr[2] == 0x63 && ptr[3] == 0x72 && ptr[4] == 0x6F { return 55 } // macro
        case 6:
            if ptr[0] == 0x72 && ptr[1] == 0x65 && ptr[2] == 0x74 && ptr[3] == 0x75 && ptr[4] == 0x72 && ptr[5] == 0x6E { return 18 } // return
            if ptr[0] == 0x73 && ptr[1] == 0x74 && ptr[2] == 0x72 && ptr[3] == 0x75 && ptr[4] == 0x63 && ptr[5] == 0x74 { return 19 } // struct
            if ptr[0] == 0x69 && ptr[1] == 0x6D && ptr[2] == 0x70 && ptr[3] == 0x6F && ptr[4] == 0x72 && ptr[5] == 0x74 { return 27 } // import
            if ptr[0] == 0x73 && ptr[1] == 0x77 && ptr[2] == 0x69 && ptr[3] == 0x74 && ptr[4] == 0x63 && ptr[5] == 0x68 { return 30 } // switch
            if ptr[0] == 0x74 && ptr[1] == 0x68 && ptr[2] == 0x72 && ptr[3] == 0x6F && ptr[4] == 0x77 && ptr[5] == 0x73 { return 37 } // throws
            if ptr[0] == 0x73 && ptr[1] == 0x74 && ptr[2] == 0x61 && ptr[3] == 0x74 && ptr[4] == 0x69 && ptr[5] == 0x63 { return 56 } // static
            if ptr[0] == 0x72 && ptr[1] == 0x65 && ptr[2] == 0x70 && ptr[3] == 0x65 && ptr[4] == 0x61 && ptr[5] == 0x74 { return 50 } // repeat
            if ptr[0] == 0x64 && ptr[1] == 0x65 && ptr[2] == 0x69 && ptr[3] == 0x6E && ptr[4] == 0x69 && ptr[5] == 0x74 { return 25 } // deinit
        case 7:
            if ptr[0] == 0x64 && ptr[1] == 0x65 && ptr[2] == 0x66 && ptr[3] == 0x61 && ptr[4] == 0x75 && ptr[5] == 0x6C && ptr[6] == 0x74 { return 32 } // default
        case 8:
            if ptr[0] == 0x63 && ptr[1] == 0x6F && ptr[2] == 0x6E && ptr[3] == 0x74 && ptr[4] == 0x69 && ptr[5] == 0x6E && ptr[6] == 0x75 && ptr[7] == 0x65 { return 34 } // continue
            if ptr[0] == 0x70 && ptr[1] == 0x72 && ptr[2] == 0x6F && ptr[3] == 0x74 && ptr[4] == 0x6F && ptr[5] == 0x63 && ptr[6] == 0x6F && ptr[7] == 0x6C { return 22 } // protocol
            if ptr[0] == 0x72 && ptr[1] == 0x65 && ptr[2] == 0x74 && ptr[3] == 0x68 && ptr[4] == 0x72 && ptr[5] == 0x6F && ptr[6] == 0x77 && ptr[7] == 0x73 { return 38 } // rethrows
            if ptr[0] == 0x6F && ptr[1] == 0x70 && ptr[2] == 0x65 && ptr[3] == 0x72 && ptr[4] == 0x61 && ptr[5] == 0x74 && ptr[6] == 0x6F && ptr[7] == 0x72 { return 53 } // operator
        case 9:
            if ptr[0] == 0x65 && ptr[1] == 0x78 && ptr[2] == 0x74 && ptr[3] == 0x65 && ptr[4] == 0x6E && ptr[5] == 0x73 && ptr[6] == 0x69 && ptr[7] == 0x6F && ptr[8] == 0x6E { return 23 } // extension
            if ptr[0] == 0x74 && ptr[1] == 0x79 && ptr[2] == 0x70 && ptr[3] == 0x65 && ptr[4] == 0x61 && ptr[5] == 0x6C && ptr[6] == 0x69 && ptr[7] == 0x61 && ptr[8] == 0x73 { return 26 } // typealias
            if ptr[0] == 0x73 && ptr[1] == 0x75 && ptr[2] == 0x62 && ptr[3] == 0x73 && ptr[4] == 0x63 && ptr[5] == 0x72 && ptr[6] == 0x69 && ptr[7] == 0x70 && ptr[8] == 0x74 { return 52 } // subscript
        case 11:
            // fallthrough
            if ptr[0] == 0x66 && ptr[1] == 0x61 && ptr[2] == 0x6C && ptr[3] == 0x6C && ptr[4] == 0x74 && ptr[5] == 0x68 && ptr[6] == 0x72 && ptr[7] == 0x6F && ptr[8] == 0x75 && ptr[9] == 0x67 && ptr[10] == 0x68 { return 35 } // fallthrough
        case 15:
            // precedencegroup
            if ptr[0] == 0x70 && ptr[1] == 0x72 && ptr[2] == 0x65 && ptr[3] == 0x63 && ptr[4] == 0x65 && ptr[5] == 0x64 && ptr[6] == 0x65 && ptr[7] == 0x6E && ptr[8] == 0x63 && ptr[9] == 0x65 && ptr[10] == 0x67 && ptr[11] == 0x72 && ptr[12] == 0x6F && ptr[13] == 0x75 && ptr[14] == 0x70 { return 54 } // precedencegroup
        default:
            break
        }
        return 1 // identifier
    }
}
