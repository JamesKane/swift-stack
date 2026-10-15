// Sources/SwiftStack/Source/Diagnostics.swift
import Foundation

/// Severity of a diagnostic (15-driver-and-diagnostics.md §4.5).
@frozen
public enum DiagSeverity: UInt8, Sendable, BitwiseCopyable, Comparable, CustomStringConvertible {
    case note = 0
    case warning = 1
    case error = 2
    case fatal = 3

    @inlinable
    public static func < (lhs: DiagSeverity, rhs: DiagSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String {
        switch self {
        case .note: return "note"
        case .warning: return "warning"
        case .error: return "error"
        case .fatal: return "fatal error"
        }
    }
}

/// Category of compiler phase emitting a diagnostic.
@frozen
public enum DiagCategory: UInt8, Sendable, BitwiseCopyable, CustomStringConvertible {
    case driver = 0
    case lex = 1
    case preprocessor = 2
    case parse = 3
    case sema = 4
    case codegen = 5
    case assembler = 6

    public var description: String {
        switch self {
        case .driver: return "driver"
        case .lex: return "lex"
        case .preprocessor: return "preprocessor"
        case .parse: return "parse"
        case .sema: return "sema"
        case .codegen: return "codegen"
        case .assembler: return "assembler"
        }
    }
}

/// Metadata description for a diagnostic kind.
public struct DiagnosticInfo: Sendable {
    public let id: DiagId
    public let name: String
    public let severity: DiagSeverity
    public let category: DiagCategory
    public let messageTemplate: String
    public let group: String?

    public init(id: DiagId, name: String, severity: DiagSeverity, category: DiagCategory, messageTemplate: String, group: String? = nil) {
        self.id = id
        self.name = name
        self.severity = severity
        self.category = category
        self.messageTemplate = messageTemplate
        self.group = group
    }

    /// Formats the message template substituting '%@' with arguments.
    public func format(args: [String]) -> String {
        var result = ""
        var argIndex = 0
        var i = messageTemplate.startIndex

        while i < messageTemplate.endIndex {
            if messageTemplate[i] == "%" && messageTemplate.index(after: i) < messageTemplate.endIndex && messageTemplate[messageTemplate.index(after: i)] == "@" {
                if argIndex < args.count {
                    result.append(args[argIndex])
                    argIndex += 1
                } else {
                    result.append("%@")
                }
                i = messageTemplate.index(i, offsetBy: 2)
            } else {
                result.append(messageTemplate[i])
                i = messageTemplate.index(after: i)
            }
        }
        return result
    }
}

/// Registry of predefined diagnostic definitions with stable IDs and names.
public final class DiagnosticRegistry: @unchecked Sendable {
    public static let shared = DiagnosticRegistry()

    private var infoTable: [UInt32: DiagnosticInfo] = [:]
    private let lock = Mutex()

    public init() {
        registerBuiltins()
    }

    public func register(_ info: DiagnosticInfo) {
        lock.withLock {
            infoTable[info.id.rawIndex] = info
        }
    }

    public func lookup(_ id: DiagId) -> DiagnosticInfo? {
        lock.withLock {
            infoTable[id.rawIndex]
        }
    }

    private func registerBuiltins() {
        // Preprocessor diagnostics
        register(DiagnosticInfo(id: .ppFileNotFound, name: "preprocessor.file_not_found", severity: .error, category: .preprocessor, messageTemplate: "include file '%@' not found"))
        register(DiagnosticInfo(id: .ppMacroRedefined, name: "preprocessor.macro_redefined", severity: .warning, category: .preprocessor, messageTemplate: "'%@' macro redefined"))
        register(DiagnosticInfo(id: .ppInvalidDirective, name: "preprocessor.invalid_directive", severity: .error, category: .preprocessor, messageTemplate: "invalid preprocessing directive '#%@'"))
        register(DiagnosticInfo(id: .ppUserError, name: "preprocessor.error_directive", severity: .error, category: .preprocessor, messageTemplate: "#error: %@"))
        register(DiagnosticInfo(id: .ppUserWarning, name: "preprocessor.warning_directive", severity: .warning, category: .preprocessor, messageTemplate: "#warning: %@"))
        register(DiagnosticInfo(id: .ppUnterminatedConditional, name: "preprocessor.unterminated_conditional", severity: .error, category: .preprocessor, messageTemplate: "unterminated '#if' conditional block"))
        register(DiagnosticInfo(id: .ppEmbedNotFound, name: "preprocessor.embed_not_found", severity: .error, category: .preprocessor, messageTemplate: "#embed resource '%@' not found"))
        register(DiagnosticInfo(id: .ppEmbedInvalidParam, name: "preprocessor.embed_invalid_param", severity: .error, category: .preprocessor, messageTemplate: "unsupported #embed parameter '%@'"))
        register(DiagnosticInfo(id: .ppExtraTokensDirective, name: "preprocessor.extra_tokens_directive", severity: .warning, category: .preprocessor, messageTemplate: "extra tokens at end of #%@ directive"))

        // Lexer diagnostics
        register(DiagnosticInfo(id: .lexUnterminatedString, name: "lex.unterminated_string", severity: .error, category: .lex, messageTemplate: "missing terminating '\"' character"))
        register(DiagnosticInfo(id: .lexUnterminatedChar, name: "lex.unterminated_char", severity: .error, category: .lex, messageTemplate: "missing terminating ''' character"))
        register(DiagnosticInfo(id: .lexInvalidNumber, name: "lex.invalid_number", severity: .error, category: .lex, messageTemplate: "invalid numeric literal suffix or format '%@'"))

        // Parser diagnostics
        register(DiagnosticInfo(id: .parseUnexpectedToken, name: "parse.unexpected_token", severity: .error, category: .parse, messageTemplate: "unexpected token '%@'"))
        register(DiagnosticInfo(id: .parseExpectedToken, name: "parse.expected_token", severity: .error, category: .parse, messageTemplate: "expected '%@'"))
        register(DiagnosticInfo(id: .parseExpectedAfter, name: "parse.expected_after", severity: .error, category: .parse, messageTemplate: "expected '%@' after %@"))
        register(DiagnosticInfo(id: .parseExpectedExpression, name: "parse.expected_expression", severity: .error, category: .parse, messageTemplate: "expected expression"))
        register(DiagnosticInfo(id: .parseExpectedType, name: "parse.expected_type", severity: .error, category: .parse, messageTemplate: "expected type specifier"))
        register(DiagnosticInfo(id: .parseExpectedIdentifier, name: "parse.expected_identifier", severity: .error, category: .parse, messageTemplate: "expected identifier"))
        register(DiagnosticInfo(id: .parseNestingLimitExceeded, name: "parse.nesting_limit_exceeded", severity: .error, category: .parse, messageTemplate: "maximum nesting depth limit (%@) exceeded"))

        // Sema diagnostics
        register(DiagnosticInfo(id: .semaUndeclaredIdentifier, name: "sema.undeclared_identifier", severity: .error, category: .sema, messageTemplate: "use of undeclared identifier '%@'"))
        register(DiagnosticInfo(id: .semaRedeclaration, name: "sema.redeclaration", severity: .error, category: .sema, messageTemplate: "redefinition of '%@' with different type"))
        register(DiagnosticInfo(id: .semaTypeMismatch, name: "sema.type_mismatch", severity: .error, category: .sema, messageTemplate: "incompatible types: cannot convert '%@' to '%@'"))
        register(DiagnosticInfo(id: .semaInvalidMember, name: "sema.invalid_member", severity: .error, category: .sema, messageTemplate: "no member named '%@' in '%@'"))
        register(DiagnosticInfo(id: .semaNotCallable, name: "sema.not_callable", severity: .error, category: .sema, messageTemplate: "called object type '%@' is not a function or function pointer"))
        register(DiagnosticInfo(id: .semaCallArgCountMismatch, name: "sema.arg_count_mismatch", severity: .error, category: .sema, messageTemplate: "too %@ arguments to function call, expected %@, have %@"))
        register(DiagnosticInfo(id: .semaGenericNoMatch, name: "sema.generic_no_match", severity: .error, category: .sema, messageTemplate: "controlling expression type '%@' not compatible with any generic association"))
        register(DiagnosticInfo(id: .semaGenericAmbiguous, name: "sema.generic_ambiguous", severity: .error, category: .sema, messageTemplate: "controlling expression type '%@' matches multiple generic associations"))
        register(DiagnosticInfo(id: .semaConstantExprNotConstant, name: "sema.not_constant_expression", severity: .error, category: .sema, messageTemplate: "expression is not an integer constant expression"))
        register(DiagnosticInfo(id: .semaIncompleteType, name: "sema.incomplete_type", severity: .error, category: .sema, messageTemplate: "variable has incomplete type '%@'"))
        register(DiagnosticInfo(id: .semaInvalidSubscript, name: "sema.invalid_subscript", severity: .error, category: .sema, messageTemplate: "subscripted value is not an array, pointer, or vector"))
        register(DiagnosticInfo(id: .semaGlobalNotSupported, name: "sema.global_not_supported", severity: .error, category: .sema, messageTemplate: "global variable '%@' is not supported in this configuration"))

        // Driver diagnostics
        register(DiagnosticInfo(id: .driverInputFileNotFound, name: "driver.file_not_found", severity: .error, category: .driver, messageTemplate: "no such file or directory: '%@'"))
        register(DiagnosticInfo(id: .driverUnrecognizedOption, name: "driver.unrecognized_option", severity: .warning, category: .driver, messageTemplate: "unrecognized command-line option '%@'"))

        // Assembler diagnostics
        register(DiagnosticInfo(id: .asmUnknownDirective, name: "assembler.unknown_directive", severity: .error, category: .assembler, messageTemplate: "unknown assembler directive '%@'"))
        register(DiagnosticInfo(id: .asmInvalidInstruction, name: "assembler.invalid_instruction", severity: .error, category: .assembler, messageTemplate: "invalid instruction '%@'"))
        register(DiagnosticInfo(id: .asmInvalidExpression, name: "assembler.invalid_expression", severity: .error, category: .assembler, messageTemplate: "invalid assembler expression '%@'"))
        register(DiagnosticInfo(id: .asmUndefinedSymbol, name: "assembler.undefined_symbol", severity: .error, category: .assembler, messageTemplate: "undefined local symbol '%@'"))
    }
}

// Common DiagId definitions
extension DiagId {
    // Preprocessor (1..19)
    public static let ppFileNotFound            = DiagId(1)
    public static let ppMacroRedefined          = DiagId(2)
    public static let ppInvalidDirective        = DiagId(3)
    public static let ppUserError               = DiagId(4)
    public static let ppUserWarning             = DiagId(5)
    public static let ppUnterminatedConditional = DiagId(6)
    public static let ppEmbedNotFound           = DiagId(7)
    public static let ppEmbedInvalidParam       = DiagId(8)
    public static let ppExtraTokensDirective    = DiagId(9)

    // Lexer (20..29)
    public static let lexUnterminatedString     = DiagId(20)
    public static let lexUnterminatedChar       = DiagId(21)
    public static let lexInvalidNumber          = DiagId(22)

    // Parser (30..49)
    public static let parseUnexpectedToken      = DiagId(30)
    public static let parseExpectedToken        = DiagId(31)
    public static let parseExpectedAfter        = DiagId(32)
    public static let parseExpectedExpression   = DiagId(33)
    public static let parseExpectedType         = DiagId(34)
    public static let parseExpectedIdentifier   = DiagId(35)
    public static let parseNestingLimitExceeded = DiagId(36)

    // Sema (50..79)
    public static let semaUndeclaredIdentifier  = DiagId(50)
    public static let semaRedeclaration         = DiagId(51)
    public static let semaTypeMismatch          = DiagId(52)
    public static let semaInvalidMember         = DiagId(53)
    public static let semaNotCallable           = DiagId(54)
    public static let semaCallArgCountMismatch  = DiagId(55)
    public static let semaGenericNoMatch        = DiagId(56)
    public static let semaGenericAmbiguous      = DiagId(57)
    public static let semaConstantExprNotConstant = DiagId(58)
    public static let semaIncompleteType        = DiagId(59)
    public static let semaInvalidSubscript      = DiagId(60)
    public static let semaGlobalNotSupported    = DiagId(61)

    // Driver (80..99)
    public static let driverInputFileNotFound   = DiagId(80)
    public static let driverUnrecognizedOption  = DiagId(81)

    // Assembler (100..119)
    public static let asmUnknownDirective       = DiagId(100)
    public static let asmInvalidInstruction     = DiagId(101)
    public static let asmInvalidExpression      = DiagId(102)
    public static let asmUndefinedSymbol        = DiagId(103)
}

/// A secondary attached note pointing to an auxiliary location.
public struct DiagNote: Sendable, Equatable {
    public let message: String
    public let location: GlobalLocation

    public init(message: String, location: GlobalLocation) {
        self.message = message
        self.location = location
    }
}

/// A source code fix-it suggesting replacement text at a range.
public struct DiagFixIt: Sendable, Equatable {
    public let location: GlobalLocation
    public let length: UInt32
    public let replacementText: String

    public init(location: GlobalLocation, length: UInt32, replacementText: String) {
        self.location = location
        self.length = length
        self.replacementText = replacementText
    }
}

/// Concrete resolved diagnostic record for rendering or export.
public struct DiagnosticRecord: Sendable {
    public let id: DiagId
    public let name: String
    public let severity: DiagSeverity
    public let category: DiagCategory
    public let location: GlobalLocation
    public let message: String
    public let notes: [DiagNote]
    public let fixIts: [DiagFixIt]
}

/// Row index handle for diagnostic entries in DiagnosticBag.
@frozen
public struct DiagRowId: TypedId {
    public let rawIndex: UInt32
    @inlinable public init(rawIndex: UInt32) { self.rawIndex = rawIndex }
    @inlinable public init(_ rawIndex: UInt32) { self.rawIndex = rawIndex }
}

/// Thread-local bag accumulating diagnostics using flat columns and arenas (15-driver-and-diagnostics.md §4.5).
public struct DiagnosticBag: ~Copyable {
    public var ids: Column<DiagRowId, UInt16>
    public var locs: Column<DiagRowId, GlobalLocation>
    public var argOffsets: Column<DiagRowId, UInt32>
    public var argCounts: Column<DiagRowId, UInt16>
    public var notesOffsets: Column<DiagRowId, UInt32>
    public var notesCounts: Column<DiagRowId, UInt16>
    public var fixItsOffsets: Column<DiagRowId, UInt32>
    public var fixItsCounts: Column<DiagRowId, UInt16>

    // Side storage
    private var argsPool: [String] = []
    private var notesPool: [DiagNote] = []
    private var fixItsPool: [DiagFixIt] = []

    public private(set) var errorCount: Int = 0
    public private(set) var warningCount: Int = 0

    public init(reservedCapacity: Int = 256) {
        self.ids = Column<DiagRowId, UInt16>(reservedCapacity: reservedCapacity, defaultNilValue: 0)
        let nilLoc = GlobalLocation(unitId: UnitId(0), location: .zero)
        self.locs = Column<DiagRowId, GlobalLocation>(reservedCapacity: reservedCapacity, defaultNilValue: nilLoc)
        self.argOffsets = Column<DiagRowId, UInt32>(reservedCapacity: reservedCapacity, defaultNilValue: 0)
        self.argCounts = Column<DiagRowId, UInt16>(reservedCapacity: reservedCapacity, defaultNilValue: 0)
        self.notesOffsets = Column<DiagRowId, UInt32>(reservedCapacity: reservedCapacity, defaultNilValue: 0)
        self.notesCounts = Column<DiagRowId, UInt16>(reservedCapacity: reservedCapacity, defaultNilValue: 0)
        self.fixItsOffsets = Column<DiagRowId, UInt32>(reservedCapacity: reservedCapacity, defaultNilValue: 0)
        self.fixItsCounts = Column<DiagRowId, UInt16>(reservedCapacity: reservedCapacity, defaultNilValue: 0)
    }

    public var count: Int {
        Int(ids.count) - 1 // Exclude nil row 0
    }

    public var hasErrors: Bool {
        errorCount > 0
    }

    /// Reports a diagnostic into the bag.
    public mutating func report(
        _ id: DiagId,
        at location: GlobalLocation,
        args: [String] = [],
        notes: [DiagNote] = [],
        fixIts: [DiagFixIt] = []
    ) {
        let info = DiagnosticRegistry.shared.lookup(id)
        let severity = info?.severity ?? .error
        if severity == .error || severity == .fatal {
            errorCount += 1
        } else if severity == .warning {
            warningCount += 1
        }

        let argOff = UInt32(argsPool.count)
        let argCnt = UInt16(min(args.count, Int(UInt16.max)))
        argsPool.append(contentsOf: args)

        let noteOff = UInt32(notesPool.count)
        let noteCnt = UInt16(min(notes.count, Int(UInt16.max)))
        notesPool.append(contentsOf: notes)

        let fixOff = UInt32(fixItsPool.count)
        let fixCnt = UInt16(min(fixIts.count, Int(UInt16.max)))
        fixItsPool.append(contentsOf: fixIts)

        _ = ids.append(UInt16(id.rawIndex & 0xFFFF))
        _ = locs.append(location)
        _ = argOffsets.append(argOff)
        _ = argCounts.append(argCnt)
        _ = notesOffsets.append(noteOff)
        _ = notesCounts.append(noteCnt)
        _ = fixItsOffsets.append(fixOff)
        _ = fixItsCounts.append(fixCnt)
    }

    /// Convenience reporting with a raw SourceLocation and UnitId 0.
    public mutating func report(
        _ id: DiagId,
        at loc: SourceLocation,
        unit: UnitId = UnitId(0),
        args: [String] = [],
        notes: [DiagNote] = [],
        fixIts: [DiagFixIt] = []
    ) {
        report(id, at: GlobalLocation(unitId: unit, location: loc), args: args, notes: notes, fixIts: fixIts)
    }

    /// Extracts all diagnostics resolved as records.
    public func records() -> [DiagnosticRecord] {
        var results: [DiagnosticRecord] = []
        let n = count
        results.reserveCapacity(n)

        for i in 1...n {
            let row = DiagRowId(UInt32(i))
            let idVal = UInt32(ids[row])
            let id = DiagId(idVal)
            let loc = locs[row]

            let aOff = Int(argOffsets[row])
            let aCnt = Int(argCounts[row])
            let aSlice = (aOff < argsPool.count && aOff + aCnt <= argsPool.count) ? Array(argsPool[aOff..<(aOff + aCnt)]) : []

            let nOff = Int(notesOffsets[row])
            let nCnt = Int(notesCounts[row])
            let nSlice = (nOff < notesPool.count && nOff + nCnt <= notesPool.count) ? Array(notesPool[nOff..<(nOff + nCnt)]) : []

            let fOff = Int(fixItsOffsets[row])
            let fCnt = Int(fixItsCounts[row])
            let fSlice = (fOff < fixItsPool.count && fOff + fCnt <= fixItsPool.count) ? Array(fixItsPool[fOff..<(fOff + fCnt)]) : []

            let info = DiagnosticRegistry.shared.lookup(id)
            let name = info?.name ?? "unknown"
            let severity = info?.severity ?? .error
            let category = info?.category ?? .sema
            let message = info?.format(args: aSlice) ?? "diagnostic \(idVal)"

            results.append(DiagnosticRecord(
                id: id,
                name: name,
                severity: severity,
                category: category,
                location: loc,
                message: message,
                notes: nSlice,
                fixIts: fSlice
            ))
        }

        return results
    }

    /// Returns diagnostics sorted deterministically by (unitId, location, diagId, message) per D6.
    public func sortedRecords() -> [DiagnosticRecord] {
        let recs = records()
        return recs.sorted { lhs, rhs in
            if lhs.location.unitId.rawIndex != rhs.location.unitId.rawIndex {
                return lhs.location.unitId.rawIndex < rhs.location.unitId.rawIndex
            }
            if lhs.location.location.rawValue != rhs.location.location.rawValue {
                return lhs.location.location.rawValue < rhs.location.location.rawValue
            }
            if lhs.id.rawIndex != rhs.id.rawIndex {
                return lhs.id.rawIndex < rhs.id.rawIndex
            }
            return lhs.message < rhs.message
        }
    }
}

/// Formats and renders diagnostics to text (with source carets) or JSON.
public enum DiagnosticRenderer {
    public enum Format {
        case text
        case json
    }

    /// Renders all diagnostics into a single formatted string.
    public static func render(
        diagnostics: borrowing DiagnosticBag,
        sourceManager: SourceManager,
        format: Format = .text,
        useColor: Bool = false
    ) -> String {
        let sorted = diagnostics.sortedRecords()
        if sorted.isEmpty { return "" }

        switch format {
        case .json:
            return renderJson(records: sorted, sourceManager: sourceManager)
        case .text:
            return renderText(records: sorted, sourceManager: sourceManager, useColor: useColor)
        }
    }

    private static func renderJson(records: [DiagnosticRecord], sourceManager: SourceManager) -> String {
        var lines: [String] = []
        for rec in records {
            var filePath = "<unknown>"
            var lineNum = 1
            var colNum = 1

            if rec.location.location.isValid,
               let match = sourceManager.file(containing: rec.location.location) {
                filePath = match.file.path
                let lc = match.file.lineTable().lineAndColumn(at: match.offset)
                lineNum = lc.line
                colNum = lc.column
            }

            let escapedMsg = rec.message.replacingOccurrences(of: "\\", with: "\\\\")
                                        .replacingOccurrences(of: "\"", with: "\\\"")
                                        .replacingOccurrences(of: "\n", with: "\\n")

            let json = "{\"file\":\"\(filePath)\",\"line\":\(lineNum),\"column\":\(colNum),\"severity\":\"\(rec.severity)\",\"id\":\"\(rec.name)\",\"message\":\"\(escapedMsg)\"}"
            lines.append(json)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func renderText(records: [DiagnosticRecord], sourceManager: SourceManager, useColor: Bool) -> String {
        var output = ""

        let red = useColor ? "\u{001B}[1;31m" : ""
        let yellow = useColor ? "\u{001B}[1;33m" : ""
        let blue = useColor ? "\u{001B}[1;36m" : ""
        let bold = useColor ? "\u{001B}[1m" : ""
        let reset = useColor ? "\u{001B}[0m" : ""

        for rec in records {
            var filePath = "<unknown>"
            var lineNum = 1
            var colNum = 1
            var lineSnippet: String? = nil

            if rec.location.location.isValid,
               let match = sourceManager.file(containing: rec.location.location) {
                filePath = match.file.path
                let lt = match.file.lineTable()
                let lc = lt.lineAndColumn(at: match.offset)
                lineNum = lc.line
                colNum = lc.column

                // Extract line snippet
                let lineIdx = lineNum - 1
                if lineIdx >= 0 && lineIdx < lt.lineStarts.count {
                    let startOff = Int(lt.lineStarts[lineIdx])
                    let endOff: Int
                    if lineIdx + 1 < lt.lineStarts.count {
                        endOff = max(startOff, Int(lt.lineStarts[lineIdx + 1]) - 1)
                    } else {
                        endOff = match.file.length
                    }
                    if endOff >= startOff && startOff < match.file.length {
                        let count = min(endOff - startOff, match.file.length - startOff)
                        if let base = match.file.buffer.baseAddress {
                            lineSnippet = String(decoding: UnsafeBufferPointer(start: base + startOff, count: count), as: UTF8.self)
                            // Strip trailing CRLF
                            if let s = lineSnippet, (s.hasSuffix("\r\n") || s.hasSuffix("\n")) {
                                lineSnippet = String(s.dropLast(s.hasSuffix("\r\n") ? 2 : 1))
                            }
                        }
                    }
                }
            }

            let colorPrefix: String
            switch rec.severity {
            case .error, .fatal: colorPrefix = red
            case .warning: colorPrefix = yellow
            case .note: colorPrefix = blue
            }

            output.append("\(bold)\(filePath):\(lineNum):\(colNum): \(colorPrefix)\(rec.severity):\(reset) \(bold)\(rec.message)\(reset) [\(rec.name)]\n")

            if let snippet = lineSnippet {
                output.append("\(snippet)\n")
                let caretIndent = max(0, colNum - 1)
                let spaces = String(repeating: " ", count: caretIndent)
                output.append("\(spaces)\(colorPrefix)^\(reset)\n")
            }

            // Attached notes
            for note in rec.notes {
                var nPath = filePath
                var nLine = lineNum
                var nCol = colNum
                if note.location.location.isValid,
                   let nMatch = sourceManager.file(containing: note.location.location) {
                    nPath = nMatch.file.path
                    let nlc = nMatch.file.lineTable().lineAndColumn(at: nMatch.offset)
                    nLine = nlc.line
                    nCol = nlc.column
                }
                output.append("\(bold)\(nPath):\(nLine):\(nCol): \(blue)note:\(reset) \(note.message)\n")
            }
        }

        return output
    }
}
