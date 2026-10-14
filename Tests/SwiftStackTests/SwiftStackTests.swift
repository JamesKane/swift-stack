import Foundation
import Testing
@testable import SwiftStack

@Suite("SwiftStack Milestone 0 Tests")
struct SwiftStackTests {
    @Test("TypedId handles and nil row 0")
    func testTypedId() {
        let nilTok = TokenId.nilId
        #expect(nilTok.isNil)
        #expect(!nilTok.isValid)
        #expect(nilTok.rawIndex == 0)

        let tok1 = TokenId(1)
        #expect(!tok1.isNil)
        #expect(tok1.isValid)
        #expect(tok1.rawIndex == 1)
    }

    @Test("Column reserve-then-commit and nil row 0 semantics")
    func testColumn() {
        var col = Column<TokenId, UInt32>(reservedCapacity: 1024)
        #expect(col.count == 1) // Row 0 is nil row
        #expect(col.rowCount == 1)
        #expect(col[TokenId.nilId] == 0)

        let id1 = col.append(42)
        #expect(id1.rawIndex == 1)
        #expect(col[id1] == 42)
        #expect(col.count == 2)

        let id2 = col.append(999)
        #expect(id2.rawIndex == 2)
        #expect(col[id2] == 999)

        // Out of bounds handle returns harmless default (row 0)
        let outOfBounds = TokenId(9999)
        #expect(col[outOfBounds] == 0)

        // Bulk append
        let batch: [UInt32] = [100, 200, 300]
        batch.withUnsafeBufferPointer { buf in
            let res = col.appendRange(buf)
            #expect(res.start.rawIndex == 3)
            #expect(res.count == 3)
        }
        #expect(col.count == 6)
        #expect(col[TokenId(3)] == 100)
        #expect(col[TokenId(4)] == 200)
        #expect(col[TokenId(5)] == 300)
    }

    @Test("Arena bump allocation and O(1) reset")
    func testArena() {
        let arena = Arena(reservedCapacity: 1024 * 1024)
        let strBuf = arena.allocateString("hello world")
        #expect(strBuf.count == 11)
        #expect(arena.bytesAllocated >= 12)

        let prevCommitted = arena.bytesCommitted
        arena.reset()
        #expect(arena.bytesAllocated == 0)
        #expect(arena.bytesCommitted == prevCommitted) // memory preserved for reuse
    }

    @Test("SourceManager buffer sentinel padding and LineTable SWAR")
    func testSourceManagerAndLineTable() {
        let sm = SourceManager()
        let code = "let x = 1\nlet y = 2\nfunc hello() {\n  return x + y\n}\n"
        let fileId = sm.addBuffer(bytes: Array(code.utf8), path: "test.swift")

        let file = sm[fileId]
        #expect(file.length == code.utf8.count)
        // Verify 64 zero sentinel bytes
        for i in file.length..<(file.length + 64) {
            #expect(file.buffer[i] == 0)
        }

        let lineTable = file.lineTable()
        #expect(lineTable.lineStarts.count >= 5)

        // Line and column checks
        let loc1 = lineTable.lineAndColumn(at: 0)
        #expect(loc1.line == 1)
        #expect(loc1.column == 1)

        let locLine2 = lineTable.lineAndColumn(at: 10) // after first '\n'
        #expect(locLine2.line == 2)
        #expect(locLine2.column == 1)
    }

    @Test("SwiftLexer scanning and token kinds")
    func testSwiftLexer() {
        let sm = SourceManager()
        let src = """
        func add(a: Int, b: Int) -> Int {
            return a + b
        }
        """
        let fileId = sm.addBuffer(bytes: Array(src.utf8), path: "add.swift")
        let file = sm[fileId]

        var tokenBuffer = TokenBuffer()
        let lexer = SwiftLexer(fileId: fileId, buffer: file.buffer, length: file.length)
        lexer.lexInto(&tokenBuffer)

        // Check tokens: row 0 is nil, followed by func, add, (, a, :, Int, ...
        #expect(tokenBuffer.count > 10)
        #expect(tokenBuffer.kind(of: TokenId(1)) == SwiftTokenKind.kwFunc.rawValue)
        #expect(tokenBuffer.kind(of: TokenId(2)) == SwiftTokenKind.identifier.rawValue)
        #expect(tokenBuffer.kind(of: TokenId(3)) == SwiftTokenKind.lParen.rawValue)
    }

    @Test("CLexer scanning and C23 keywords")
    func testCLexer() {
        let sm = SourceManager()
        let cSrc = """
        #include <stdio.h>
        int main(void) {
            auto x = 1'000'000;
            constexpr bool flag = true;
            return 0;
        }
        """
        let fileId = sm.addBuffer(bytes: Array(cSrc.utf8), path: "main.c")
        let file = sm[fileId]

        var tokenBuffer = TokenBuffer()
        let lexer = CLexer(fileId: fileId, buffer: file.buffer, length: file.length)
        lexer.lexInto(&tokenBuffer)

        #expect(tokenBuffer.count > 10)
        // Verify token kinds include C keywords: int, auto, constexpr, bool, true, return
        var foundAuto = false
        var foundConstexpr = false
        var foundBool = false
        var foundTrue = false

        for i in 1..<tokenBuffer.count {
            let k = tokenBuffer.kind(of: TokenId(UInt32(i)))
            if k == CTokenKind.kwAuto.rawValue { foundAuto = true }
            if k == CTokenKind.kwConstexpr.rawValue { foundConstexpr = true }
            if k == CTokenKind.kwBool.rawValue { foundBool = true }
            if k == CTokenKind.kwTrue.rawValue { foundTrue = true }
        }

        #expect(foundAuto)
        #expect(foundConstexpr)
        #expect(foundBool)
        #expect(foundTrue)
    }

    @Test("Profiler and RepetitionTester")
    func testProfilerAndRepetitionTester() {
        let profiler = Profiler.shared
        profiler.reset()
        profiler.isEnabled = true

        let cycles = Profiler.readCycles()
        #expect(cycles > 0)
        #expect(profiler.cpuFrequencyHz > 100_000_000)

        profiler.timeBlock(name: "TestBlock", category: "test") {
            var sum = 0
            for i in 0..<1000 { sum += i }
            #expect(sum > 0)
        }

        let trace = profiler.exportTraceJSON()
        #expect(trace.contains("TestBlock"))

        // RepetitionTester on SwiftLexer
        let src = "func compute(x: Int) -> Int { return x * 2 + 1 }\n"
        let sm = SourceManager()
        let fileId = sm.addBuffer(bytes: Array(src.utf8), path: "bench.swift")
        let file = sm[fileId]

        let tester = RepetitionTester(targetDurationSeconds: 0.05, maxIterations: 50)
        var tb = TokenBuffer()
        let res = tester.testKernel(name: "SwiftLexer", byteCount: file.length) {
            tb = TokenBuffer()
            let lex = SwiftLexer(fileId: fileId, buffer: file.buffer, length: file.length)
            lex.lexInto(&tb)
        }

        #expect(res.iterations >= 2)
        #expect(res.bestCycles > 0)
        #expect(res.bandwidthMBs > 0)
    }

    @Test("FeatureCensus scanner")
    func testFeatureCensus() {
        let census = FeatureCensus()
        let sample = """
        @_noAllocation
        func hotPath() {}

        @c(my_export)
        func exportedFunc() {}

        struct SafeStruct: ~Copyable, ~Escapable {
            var span: Span<Int>
        }
        """
        census.scanFile(content: sample)
        let results = census.results()
        let noAlloc = results.first { $0.name == "@_noAllocation" }
        #expect(noAlloc != nil && noAlloc!.count == 1)

        let atC = results.first { $0.name == "@c" }
        #expect(atC != nil && atC!.count == 1)

        let span = results.first { $0.name == "Span" }
        #expect(span != nil && span!.count == 1)
    }

    @Test("ParseTree postorder layout and children navigation")
    func testParseTree() {
        var pt = ParseTree()
        #expect(pt.count == 1) // nil root
        let leaf1 = pt.appendLeaf(kind: .intLiteral, token: TokenId(1))
        let leaf2 = pt.appendLeaf(kind: .intLiteral, token: TokenId(2))
        let binOp = pt.append(kind: .binaryExpr, token: TokenId(3), subtreeSize: 3)

        #expect(pt.count == 4)
        let ch = pt.children(of: binOp)
        #expect(ch.count == 2)
        #expect(ch[0] == leaf1)
        #expect(ch[1] == leaf2)
    }

    @Test("CParser and CSemanticAnalyzer")
    func testCParserAndSemantics() {
        let sm = SourceManager()
        let src = """
        int add(int a, int b) {
            return a + b;
        }
        int main() {
            int x = 10;
            return add(x, 20);
        }
        """
        let fileId = sm.addBuffer(bytes: Array(src.utf8), path: "test.c")
        let file = sm[fileId]

        var tokenBuffer = TokenBuffer()
        let lexer = CLexer(fileId: fileId, buffer: file.buffer, length: file.length)
        lexer.lexInto(&tokenBuffer)

        withUnsafePointer(to: tokenBuffer) { tbPtr in
            let parser = CParser(tokens: tbPtr, sourceBuffer: file.buffer.baseAddress!, sourceLength: file.length)
            let tree = parser.parse()

            #expect(tree.count > 10)

            var sem = CSemanticAnalyzer(typePool: TypePool(), sourceBuffer: file.buffer.baseAddress!, sourceLength: file.length)
            let semResult = sem.analyze(tree: tree, tokens: tokenBuffer)

            #expect(semResult.functions["add"] != nil)
            #expect(semResult.functions["main"] != nil)
            #expect(semResult.diagnostics.isEmpty)
        }
    }

    @Test("End-to-end C program compilation and execution")
    func testEndToEndExecution() throws {
        let tempDir = FileManager.default.temporaryDirectory

        let programs: [(file: String, expectedExit: Int32)] = [
            ("Benchmarks/corpora/c-subset/00_exit42.c", 42),
            ("Benchmarks/corpora/c-subset/02_arith.c", 40),
            ("Benchmarks/corpora/c-subset/03_bitwise.c", 45),
            ("Benchmarks/corpora/c-subset/04_locals.c", 55),
            ("Benchmarks/corpora/c-subset/05_if_else.c", 70),
            ("Benchmarks/corpora/c-subset/06_while_sum.c", 55),
            ("Benchmarks/corpora/c-subset/07_functions.c", 55),
            ("Benchmarks/corpora/c-subset/08_recursion.c", 55),
            ("Benchmarks/corpora/c-subset/09_pointers.c", 50),
            ("Benchmarks/corpora/c-subset/10_collatz.c", 16),
        ]

        for (relPath, expectedCode) in programs {
            let outBinary = tempDir.appendingPathComponent("ss_test_\(UUID().uuidString)").path
            defer { try? FileManager.default.removeItem(atPath: outBinary) }

            var opts = DriverOptions()
            opts.inputFiles = [relPath]
            opts.outputBinaryPath = outBinary
            opts.runBinary = true

            let pipeline = DriverPipeline(options: opts)
            let exitCode = try pipeline.run()
            #expect(exitCode == expectedCode, "Execution of \(relPath) returned \(exitCode), expected \(expectedCode)")
        }
    }
}
