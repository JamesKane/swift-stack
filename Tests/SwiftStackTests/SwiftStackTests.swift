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

    @Test("SwiftLexer keyword matching, while bug, and token descriptions")
    func testSwiftLexerKeywordsAndDescription() {
        let sm = SourceManager()
        let src = "while break continue fallthrough precedencegroup func let var"
        let fileId = sm.addBuffer(bytes: Array(src.utf8), path: "keywords.swift")
        let file = sm[fileId]

        var tokenBuffer = TokenBuffer()
        let lexer = SwiftLexer(fileId: fileId, buffer: file.buffer, length: file.length, baseLocation: file.baseLocation)
        lexer.lexInto(&tokenBuffer)

        #expect(tokenBuffer.kind(of: TokenId(1)) == SwiftTokenKind.kwWhile.rawValue)
        #expect(tokenBuffer.kind(of: TokenId(2)) == SwiftTokenKind.kwBreak.rawValue)
        #expect(tokenBuffer.kind(of: TokenId(3)) == SwiftTokenKind.kwContinue.rawValue)
        #expect(tokenBuffer.kind(of: TokenId(4)) == SwiftTokenKind.kwFallthrough.rawValue)
        #expect(tokenBuffer.kind(of: TokenId(5)) == SwiftTokenKind.kwPrecedencegroup.rawValue)

        // Verify description on all Swift and C token kinds does not segfault
        for raw in 0...UInt8(255) {
            if let sk = SwiftTokenKind(rawValue: raw) {
                _ = sk.description
            }
            if let ck = CTokenKind(rawValue: raw) {
                _ = ck.description
            }
        }
    }

    @Test("CLexer compound assignments and unterminated error handling")
    func testCLexerCompoundsAndErrors() {
        let sm = SourceManager()
        let src = "+= -= *= /= %= &= |= ^= <<= >>="
        let fileId = sm.addBuffer(bytes: Array(src.utf8), path: "compounds.c")
        let file = sm[fileId]

        var tokenBuffer = TokenBuffer()
        let lexer = CLexer(fileId: fileId, buffer: file.buffer, length: file.length, baseLocation: file.baseLocation)
        lexer.lexInto(&tokenBuffer)

        #expect(tokenBuffer.kind(of: TokenId(1)) == CTokenKind.plusEqual.rawValue)
        #expect(tokenBuffer.kind(of: TokenId(2)) == CTokenKind.minusEqual.rawValue)
        #expect(tokenBuffer.kind(of: TokenId(3)) == CTokenKind.starEqual.rawValue)
        #expect(tokenBuffer.kind(of: TokenId(4)) == CTokenKind.slashEqual.rawValue)
        #expect(tokenBuffer.kind(of: TokenId(5)) == CTokenKind.percentEqual.rawValue)
        #expect(tokenBuffer.kind(of: TokenId(6)) == CTokenKind.ampEqual.rawValue)
        #expect(tokenBuffer.kind(of: TokenId(7)) == CTokenKind.pipeEqual.rawValue)
        #expect(tokenBuffer.kind(of: TokenId(8)) == CTokenKind.caretEqual.rawValue)
        #expect(tokenBuffer.kind(of: TokenId(9)) == CTokenKind.lessLessEqual.rawValue)
        #expect(tokenBuffer.kind(of: TokenId(10)) == CTokenKind.greaterGreaterEqual.rawValue)

        // Unterminated block comment in C
        let unclosedCComment = "int x = 1; /* unclosed comment"
        let ucId = sm.addBuffer(bytes: Array(unclosedCComment.utf8), path: "uc.c")
        var ucBuf = TokenBuffer()
        CLexer(fileId: ucId, buffer: sm[ucId].buffer, length: sm[ucId].length).lexInto(&ucBuf)
        var hasErrorToken = false
        for i in 1..<ucBuf.count {
            if ucBuf.kind(of: TokenId(UInt32(i))) == CTokenKind.errorToken.rawValue ||
               (ucBuf.flag(of: TokenId(UInt32(i))) & (1 << 7)) != 0 {
                hasErrorToken = true
            }
        }
        #expect(hasErrorToken)

        // Unterminated string in Swift
        let unclosedSwiftString = "let s = \"hello"
        let usId = sm.addBuffer(bytes: Array(unclosedSwiftString.utf8), path: "us.swift")
        var usBuf = TokenBuffer()
        SwiftLexer(fileId: usId, buffer: sm[usId].buffer, length: sm[usId].length).lexInto(&usBuf)
        var hasSwiftErrorToken = false
        for i in 1..<usBuf.count {
            if usBuf.kind(of: TokenId(UInt32(i))) == SwiftTokenKind.errorToken.rawValue ||
               (usBuf.flag(of: TokenId(UInt32(i))) & (1 << 7)) != 0 {
                hasSwiftErrorToken = true
            }
        }
        #expect(hasSwiftErrorToken)
    }

    @Test("Multi-file location uniqueness")
    func testMultiFileLocationUniqueness() {
        let sm = SourceManager()
        let file1Id = sm.addBuffer(bytes: Array("int a = 1;".utf8), path: "a.c")
        let file2Id = sm.addBuffer(bytes: Array("int b = 2;".utf8), path: "b.c")

        let file1 = sm[file1Id]
        let file2 = sm[file2Id]

        #expect(file1.baseLocation.rawValue != file2.baseLocation.rawValue)
        #expect(file2.baseLocation.rawValue >= file1.baseLocation.rawValue + UInt32(file1.length))
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

            let sem = CSemanticAnalyzer(typePool: TypePool(), sourceBuffer: file.buffer.baseAddress!, sourceLength: file.length)
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

    @Test("Compiler miscompilation regression suite (Bugs 1-10)")
    func testMiscompilationRegressions() throws {
        let tempDir = FileManager.default.temporaryDirectory

        func compileAndRun(cCode: String) throws -> Int32 {
            let srcPath = tempDir.appendingPathComponent("reg_\(UUID().uuidString).c").path
            let binPath = tempDir.appendingPathComponent("reg_\(UUID().uuidString).bin").path
            defer {
                try? FileManager.default.removeItem(atPath: srcPath)
                try? FileManager.default.removeItem(atPath: binPath)
            }
            try cCode.write(toFile: srcPath, atomically: true, encoding: .utf8)
            var opts = DriverOptions()
            opts.inputFiles = [srcPath]
            opts.outputBinaryPath = binPath
            opts.runBinary = true
            let pipeline = DriverPipeline(options: opts)
            return try pipeline.run()
        }

        // Bug 1: Saved callee-saved registers sharing stack slots with locals
        let bug1 = """
        int sub(int x) { return x - 1; }
        int compute(int n) {
            int x = 100;
            int i = 0;
            while (i < n) {
                x = x - sub(2);
                i = i + 1;
            }
            return x;
        }
        int main() { return compute(6); }
        """
        #expect(try compileAndRun(cCode: bug1) == 94)

        // Bug 2: Spilling both operands in arithmetic operation
        let bug2 = """
        int test_spill(int a, int b, int c, int d, int e, int f) {
            int v1 = a + 1;
            int v2 = b + 2;
            int v3 = c + 3;
            int v4 = d + 4;
            int v5 = e + 5;
            int v6 = f + 6;
            return (v1 + v6) + (v2 + v5) + (v3 + v4);
        }
        int main() { return test_spill(1, 2, 3, 4, 5, 6); }
        """
        #expect(try compileAndRun(cCode: bug2) == 42)

        // Bug 3: Spilled divisor in division
        let bug3 = """
        int test_div_spill(int a, int b, int c, int d, int e, int f) {
            int v1 = a + 1;
            int v2 = b + 2;
            int v3 = c + 3;
            int v4 = d + 4;
            int v5 = e + 5;
            int v6 = f + 6;
            int div = 100 / v1;
            return div + v2 + v3 + v4 + v5 + v6;
        }
        int main() { return test_div_spill(1, 2, 3, 4, 5, 6); }
        """
        #expect(try compileAndRun(cCode: bug3) == 90)

        // Bug 4: Store through spilled pointer
        let bug4 = """
        int test_ptr_spill(int a, int b, int c, int d, int e, int f) {
            int target = 0;
            int *ptr = &target;
            int v1 = a + 1;
            int v2 = b + 2;
            int v3 = c + 3;
            int v4 = d + 4;
            int v5 = e + 5;
            int v6 = f + 6;
            *ptr = 42;
            return target + (v1 - 2) + (v2 - 4) + (v3 - 6) + (v4 - 8) + (v5 - 10) + (v6 - 12);
        }
        int main() { return test_ptr_spill(1, 2, 3, 4, 5, 6); }
        """
        #expect(try compileAndRun(cCode: bug4) == 42)

        // Bug 5: 7+ arguments and parameters (System V stack passing)
        let bug5 = """
        int sum8(int a, int b, int c, int d, int e, int f, int g, int h) {
            return a + b + c + d + e + f + g + h;
        }
        int main() { return sum8(1, 2, 3, 4, 5, 6, 7, 8); }
        """
        #expect(try compileAndRun(cCode: bug5) == 36)

        // Bug 6: Logical AND/OR short-circuiting and boolean results
        let bug6 = """
        int side_effect(int *p) {
            *p = *p + 1;
            return 1;
        }
        int main() {
            int x = 0;
            int a = 0 && side_effect(&x);
            int b = 1 || side_effect(&x);
            int c = (2 && 3);
            int d = (4 || 0);
            return x + a + b + c + d;
        }
        """
        #expect(try compileAndRun(cCode: bug6) == 3)

        // Bug 7: Global variables rejection
        let bug7 = """
        int global_var = 10;
        int main() { return global_var; }
        """
        #expect(try compileAndRun(cCode: bug7) != 0)

        // Bug 8: 64-bit integer literal evaluation
        let bug8 = """
        long test_large() {
            long x = 4294967301;
            return x - 4294967296;
        }
        int main() { return test_large(); }
        """
        #expect(try compileAndRun(cCode: bug8) == 5)

        // Bug 9: Pointer arithmetic scaling and difference
        let bug9 = """
        int test_ptr_diff() {
            int a = 0;
            int b = 0;
            int c = 0;
            int *p0 = &a;
            int *p3 = p0 + 3;
            long diff = p3 - p0;
            return diff;
        }
        int main() { return test_ptr_diff(); }
        """
        #expect(try compileAndRun(cCode: bug9) == 3)

        // Bug 10: Determinism with colliding function names fcel/fkba
        let bug10 = """
        int fcel() { return 11; }
        int fkba() { return 22; }
        int main() { return fcel(); }
        """
        let src10 = tempDir.appendingPathComponent("bug10.c").path
        let bin10A = tempDir.appendingPathComponent("bug10_a.bin").path
        let bin10B = tempDir.appendingPathComponent("bug10_b.bin").path
        defer {
            try? FileManager.default.removeItem(atPath: src10)
            try? FileManager.default.removeItem(atPath: bin10A)
            try? FileManager.default.removeItem(atPath: bin10B)
        }
        try bug10.write(toFile: src10, atomically: true, encoding: .utf8)
        var optA = DriverOptions()
        optA.inputFiles = [src10]
        optA.outputBinaryPath = bin10A
        _ = try DriverPipeline(options: optA).run()

        var optB = DriverOptions()
        optB.inputFiles = [src10]
        optB.outputBinaryPath = bin10B
        _ = try DriverPipeline(options: optB).run()

        let dataA = try Data(contentsOf: URL(fileURLWithPath: bin10A))
        let dataB = try Data(contentsOf: URL(fileURLWithPath: bin10B))
        #expect(dataA == dataB)
    }

    @Test("Differential testing against GCC on C-subset corpus")
    func testDifferentialGCC() throws {
        let tempDir = FileManager.default.temporaryDirectory

        let programs = [
            "Benchmarks/corpora/c-subset/00_exit42.c",
            "Benchmarks/corpora/c-subset/02_arith.c",
            "Benchmarks/corpora/c-subset/03_bitwise.c",
            "Benchmarks/corpora/c-subset/04_locals.c",
            "Benchmarks/corpora/c-subset/05_if_else.c",
            "Benchmarks/corpora/c-subset/06_while_sum.c",
            "Benchmarks/corpora/c-subset/07_functions.c",
            "Benchmarks/corpora/c-subset/08_recursion.c",
            "Benchmarks/corpora/c-subset/09_pointers.c",
            "Benchmarks/corpora/c-subset/10_collatz.c",
        ]

        for relPath in programs {
            let ssBin = tempDir.appendingPathComponent("ss_\(UUID().uuidString)").path
            let gccBin = tempDir.appendingPathComponent("gcc_\(UUID().uuidString)").path
            defer {
                try? FileManager.default.removeItem(atPath: ssBin)
                try? FileManager.default.removeItem(atPath: gccBin)
            }

            var opts = DriverOptions()
            opts.inputFiles = [relPath]
            opts.outputBinaryPath = ssBin
            opts.runBinary = true
            let ssExit = try DriverPipeline(options: opts).run()

            // Run GCC
            let gccProcess = Process()
            gccProcess.executableURL = URL(fileURLWithPath: "/usr/bin/gcc")
            gccProcess.arguments = [relPath, "-o", gccBin]
            try gccProcess.run()
            gccProcess.waitUntilExit()
            #expect(gccProcess.terminationStatus == 0)

            let runProcess = Process()
            runProcess.executableURL = URL(fileURLWithPath: gccBin)
            try runProcess.run()
            runProcess.waitUntilExit()
            let gccExit = runProcess.terminationStatus

            #expect(ssExit == gccExit, "Differential mismatch on \(relPath): ss=\(ssExit), gcc=\(gccExit)")
        }
    }

    @Test("Diagnostics engine bag storage, caret excerpt rendering, and JSON formatting")
    func testDiagnosticsEngine() {
        let sm = SourceManager()
        let code = """
        int main() {
            int x = 10
            return x;
        }
        """
        let fileId = sm.addBuffer(bytes: Array(code.utf8), path: "main.c")
        let file = sm[fileId]

        var bag = DiagnosticBag()
        let count0 = bag.count
        let hasErrors0 = bag.hasErrors
        #expect(count0 == 0)
        #expect(!hasErrors0)

        // Add error at line 2, col 15 (after 'int x = 10')
        let loc = SourceLocation(file.baseLocation.rawValue + 27) // roughly around '10'
        let noteLoc = SourceLocation(file.baseLocation.rawValue + 4) // around 'main'
        let note = DiagNote(message: "in function definition", location: GlobalLocation(unitId: UnitId(0), location: noteLoc))
        let fixIt = DiagFixIt(location: GlobalLocation(unitId: UnitId(0), location: loc), length: 0, replacementText: ";")

        bag.report(.parseExpectedAfter, at: loc, args: [";", "expression"], notes: [note], fixIts: [fixIt])

        let count1 = bag.count
        let hasErrors1 = bag.hasErrors
        let errorCount1 = bag.errorCount
        #expect(count1 == 1)
        #expect(hasErrors1)
        #expect(errorCount1 == 1)

        // Render text
        let textOutput = DiagnosticRenderer.render(diagnostics: bag, sourceManager: sm, format: .text, useColor: false)
        #expect(textOutput.contains("main.c:"))
        #expect(textOutput.contains("error: expected ';' after expression [parse.expected_after]"))
        #expect(textOutput.contains("note: in function definition"))
        #expect(textOutput.contains("^")) // caret excerpt

        // Render JSON
        let jsonOutput = DiagnosticRenderer.render(diagnostics: bag, sourceManager: sm, format: .json)
        #expect(jsonOutput.contains("\"file\":\"main.c\""))
        #expect(jsonOutput.contains("\"severity\":\"error\""))
        #expect(jsonOutput.contains("\"id\":\"parse.expected_after\""))
        #expect(jsonOutput.contains("\"message\":\"expected ';' after expression\""))
    }

    @Test("C23 Preprocessor macro expansion, directives, conditionals, and #embed")
    func testCPreprocessor() throws {
        let sm = SourceManager()
        let pp = CPreprocessor(sourceManager: sm)

        // 1. Predefined macros check
        #expect(pp.isMacroDefined("__STDC__"))
        #expect(pp.isMacroDefined("__STDC_VERSION__"))
        #expect(pp.isMacroDefined("__x86_64__"))
        #expect(pp.isMacroDefined("__linux__"))

        // 2. Conditionals evaluation
        let codeCond = """
        #if defined(__x86_64__) && 10 > 5
        int arch = 64;
        #else
        int arch = 32;
        #endif

        #if __has_c_attribute(nodiscard)
        int has_nodiscard = 1;
        #endif

        #if __has_builtin(__builtin_expect)
        int has_expect = 1;
        #endif
        """
        let fCond = sm.addBuffer(bytes: Array(codeCond.utf8), path: "cond.c")
        var tbCond = TokenBuffer()
        pp.preprocess(fileId: fCond, into: &tbCond)

        // Verify tokens in output
        let sfCond = sm[fCond]
        var tokensCond: [String] = []
        for i in 1..<Int(tbCond.count) {
            let tid = TokenId(UInt32(i))
            let s = tbCond.start(of: tid)
            let e = tbCond.end(of: tid)
            let off = Int(s.rawValue - sfCond.baseLocation.rawValue)
            let len = Int(e.rawValue - s.rawValue)
            if off >= 0 && len > 0 && off + len <= sfCond.length {
                tokensCond.append(String(decoding: UnsafeBufferPointer(start: sfCond.buffer.baseAddress! + off, count: len), as: UTF8.self))
            }
        }
        #expect(tokensCond.contains("arch"))
        #expect(tokensCond.contains("64"))
        #expect(!tokensCond.contains("32"))
        #expect(tokensCond.contains("has_nodiscard"))
        #expect(tokensCond.contains("has_expect"))

        // 3. Macro expansion: function-like, stringizing, token pasting, __VA_OPT__
        let codeMacros = """
        #define ADD(a, b) ((a) + (b))
        #define STR(x) #x
        #define CONCAT(a, b) a ## b
        #define LOG(fmt, ...) printf(fmt __VA_OPT__(,) __VA_ARGS__)

        int r1 = ADD(10, 20);
        char *r2 = STR(hello world);
        int r3 = CONCAT(foo, bar);
        LOG("simple");
        LOG("with args", 1, 2);
        """
        let fMacros = sm.addBuffer(bytes: Array(codeMacros.utf8), path: "macros.c")
        var tbMacros = TokenBuffer()
        pp.preprocess(fileId: fMacros, into: &tbMacros)

        var macroKinds: [CTokenKind] = []
        for i in 1..<Int(tbMacros.count) {
            let tid = TokenId(UInt32(i))
            macroKinds.append(CTokenKind(rawValue: tbMacros.kind(of: tid))!)
        }
        // Check that macro expansions produced expected kinds
        #expect(macroKinds.contains(.stringLiteral)) // from STR and LOG
        #expect(macroKinds.contains(.plus))          // from ADD

        // 4. C23 #embed
        let tempDir = FileManager.default.temporaryDirectory
        let assetPath = tempDir.appendingPathComponent("test_data.bin").path
        let assetBytes: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        try Data(assetBytes).write(to: URL(fileURLWithPath: assetPath))
        defer { try? FileManager.default.removeItem(atPath: assetPath) }

        let codeEmbed = """
        const unsigned char data[] = {
        #embed "\(assetPath)" limit(2) prefix(0xFF,) suffix(,0x00)
        };
        """
        let fEmbed = sm.addBuffer(bytes: Array(codeEmbed.utf8), path: "embed.c")
        var tbEmbed = TokenBuffer()
        pp.preprocess(fileId: fEmbed, into: &tbEmbed)

        var hasEmbedAsset = false
        for i in 1..<Int(tbEmbed.count) {
            let tid = TokenId(UInt32(i))
            if CTokenKind(rawValue: tbEmbed.kind(of: tid)) == .embedAsset {
                hasEmbedAsset = true
            }
        }
        #expect(hasEmbedAsset)
    }

    @Test("C23 Parser for structs, enums with underlying type, typedefs, designated initializers, and expressions")
    func testC23Parser() {
        let sm = SourceManager()
        let src = """
        typedef struct Point {
            int x;
            int y;
        } Point_t;

        enum Status : unsigned char {
            OK = 0,
            ERROR = 1
        };

        [[nodiscard]] static inline int compute(Point_t *pt, int bias) {
            if (!pt) return -1;
            auto total = pt->x + pt->y * bias;
            for (int i = 0; i < 10; i++) {
                total += i;
            }
            switch (bias) {
            case 0: return total;
            default: break;
            }
            return total > 0 ? total : 0;
        }

        int main() {
            Point_t p = { .x = 10, .y = 20 };
            return compute(&p, 2);
        }
        """
        let fId = sm.addBuffer(bytes: Array(src.utf8), path: "c23_test.c")
        var tb = TokenBuffer()
        let lexer = CLexer(fileId: fId, buffer: sm[fId].buffer, length: sm[fId].length, baseLocation: sm[fId].baseLocation)
        lexer.lexInto(&tb)

        let tree = withUnsafePointer(to: tb) { tbPtr in
            let parser = CParser(tokens: tbPtr, sourceBuffer: sm[fId].buffer.baseAddress!, sourceLength: sm[fId].length)
            return parser.parse()
        }

        #expect(tree.count > 10)
        let rootNode = NodeId(tree.count - 1)
        let rootKind = tree.kind(of: rootNode)
        let hasErr = tree.hasError(node: rootNode)
        #expect(rootKind == .translationUnit)
        #expect(!hasErr)
    }

    @Test("C23 Semantic Analysis, TypePool, DeclTable, anonymous structs/unions, typeof, _Generic, and static_assert")
    func testC23SemanticAnalysisAndSemIR() {
        let sm = SourceManager()
        let src = """
        typedef struct Packet {
            int tag;
            union {
                long i64;
                struct {
                    int lo;
                    int hi;
                };
            };
        } Packet_t, *PacketPtr_t;

        static_assert(sizeof(Packet_t) >= 16, "Packet size check");

        static int process_packet(PacketPtr_t pkt) {
            typeof(pkt->lo) val = pkt->lo + pkt->hi;
            int kind = _Generic(val,
                int: 1,
                long: 2,
                default: 0
            );
            return val + kind;
        }
        """
        let fId = sm.addBuffer(bytes: Array(src.utf8), path: "sema_c23.c")
        let pp = CPreprocessor(sourceManager: sm)
        var tb = TokenBuffer()
        pp.preprocess(fileId: fId, into: &tb)
        let ppHasErrors = pp.diagnostics.hasErrors
        #expect(!ppHasErrors)

        let sf = sm[fId]
        let tree = withUnsafePointer(to: tb) { tbPtr in
            let parser = CParser(
                tokens: tbPtr,
                sourceBuffer: sf.buffer.baseAddress!,
                sourceLength: sf.length,
                sourceManager: sm
            )
            return parser.parse()
        }

        let analyzer = CSemanticAnalyzer(
            typePool: TypePool(),
            sourceBuffer: sf.buffer.baseAddress!,
            sourceLength: sf.length,
            sourceManager: sm
        )
        let semResult = analyzer.analyze(tree: tree, tokens: tb)
        let semHasErrors = semResult.semModule.diagnosticBag.hasErrors
        let declCount = semResult.semModule.declTable.count
        let instBlocksEmpty = semResult.semModule.instBlocks.isEmpty
        #expect(!semHasErrors)
        #expect(declCount >= 4)
        #expect(!instBlocksEmpty)
    }

    @Test("Host glibc headers preprocess, parse, and type-check cleanly")
    func testHostGlibcHeaders() {
        let sm = SourceManager()
        let src = """
        #include <stdint.h>
        #include <stddef.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>

        int check_headers(const char *s) {
            size_t n = strlen(s);
            uint64_t v = (uint64_t)n;
            return (int)v;
        }
        """
        let fId = sm.addBuffer(bytes: Array(src.utf8), path: "host_headers.c")
        let pp = CPreprocessor(sourceManager: sm)
        var tb = TokenBuffer()
        pp.preprocess(fileId: fId, into: &tb)
        let ppHasErrors = pp.diagnostics.hasErrors
        #expect(!ppHasErrors)

        let sf = sm[fId]
        let tree = withUnsafePointer(to: tb) { tbPtr in
            let parser = CParser(
                tokens: tbPtr,
                sourceBuffer: sf.buffer.baseAddress!,
                sourceLength: sf.length,
                sourceManager: sm
            )
            return parser.parse()
        }

        let analyzer = CSemanticAnalyzer(
            typePool: TypePool(),
            sourceBuffer: sf.buffer.baseAddress!,
            sourceLength: sf.length,
            sourceManager: sm
        )
        let semResult = analyzer.analyze(tree: tree, tokens: tb)
        let semHasErrors = semResult.semModule.diagnosticBag.hasErrors
        #expect(!semHasErrors)
    }
}

// MARK: - M2: Encoders, Object Model, and Assemblers

@Suite("M2 — Encoders, Object Model, and Assemblers")
struct M2EncodersObjectAssemblersTests {

    @Test("x86-64 table-driven encoder & disassembler exhaustive round-trip (including VEX)")
    func testX86InstructionTableRoundTrip() throws {
        let results = try X86InstructionTable.verifyRoundTrip()
        #expect(results.count >= X86InstructionTable.descriptors.count)
    }

    @Test("AArch64 table-driven encoder & disassembler exhaustive round-trip (including NEON & SVE)")
    func testAArch64InstructionTableRoundTrip() {
        let results = A64InstructionTable.verifyRoundTrip()
        #expect(results.count == A64InstructionTable.entries.count)
    }

    @Test("RV64 (RVA23) table-driven encoder & disassembler exhaustive round-trip (including RVC & RVV)")
    func testRV64InstructionTableRoundTrip() {
        let results = RV64InstructionTable.verifyRoundTrip()
        #expect(results.count == RV64InstructionTable.descriptors.count)
    }

    @Test("ELF64 ET_REL deterministic writer & reader round-trip across x86-64, AArch64, and RV64")
    func testELFRelocatableObjectRoundTrip() throws {
        for arch in [ObjectArch.x86_64, ObjectArch.aarch64, ObjectArch.riscv64] {
            var obj = RelocatableObject(origin: .assembled, arch: arch)
            let textSec = obj.addSection(name: ".text", kind: .text, flags: [.alloc, .execInstr], alignLog2: 4)
            let dataSec = obj.addSection(name: ".data", kind: .data, flags: [.alloc, .write], alignLog2: 3)
            let bssSec = obj.addSection(name: ".bss", kind: .bss, flags: [.alloc, .write], alignLog2: 3)

            obj.appendSectionBytes(textSec, [0x90, 0x90, 0xC3, 0x00])
            obj.appendSectionBytes(dataSec, [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
            obj.setNobitsSectionSize(bssSec, size: 64)

            let localSym = obj.addSymbol(
                name: ".Llocal",
                section: textSec,
                value: 0,
                size: 4,
                binding: .local,
                visibility: .defaultVisibility,
                kind: .notype
            )
            let globalSym = obj.addSymbol(
                name: "entry_fn",
                section: textSec,
                value: 0,
                size: 4,
                binding: .global,
                visibility: .defaultVisibility,
                kind: .funcSymbol
            )
            let extSym = obj.addSymbol(
                name: "ext_target",
                section: .undefined,
                value: 0,
                size: 0,
                binding: .global,
                visibility: .defaultVisibility,
                kind: .notype
            )
            _ = localSym
            _ = globalSym

            let relocKind: RelocKind
            switch arch {
            case .x86_64:  relocKind = .x86_64_plt32
            case .aarch64: relocKind = .aarch64_call26
            case .riscv64: relocKind = .riscv_call_plt
            }
            obj.addRelocation(to: textSec, offset: 0, symbol: extSym, kind: relocKind, addend: -4)

            let elfBytes1 = ELFObjectWriter.write(obj)
            let elfBytes2 = ELFObjectWriter.write(obj)
            #expect(elfBytes1 == elfBytes2)

            let parsed = try ELFObjectReader.read(bytes: elfBytes1)
            #expect(parsed.arch == arch)
            #expect(parsed.sectionCount == obj.sectionCount)
            #expect(parsed.symbolCount == obj.symbolCount)
            #expect(parsed.relocCount == obj.relocCount)

            let reserialized = ELFObjectWriter.write(parsed)
            #expect(reserialized == elfBytes1)
        }
    }

    @Test("Differential assembly: Todhchai floor entry (.S) across amd64, arm64, and rv64")
    func testTodhchaiDifferentialAssembly() throws {
        let baseDir = "/home/jkane/Projects/OS/todhchai/system/sys/floor/entry"
        guard FileManager.default.fileExists(atPath: baseDir) else { return }

        let targets: [(file: String, arch: AssemblerArch, clangTarget: String, extraFlags: [String])] = [
            ("amd64.S", .x86_64, "x86_64-unknown-none-elf", []),
            ("arm64.S", .aarch64, "aarch64-unknown-none-elf", []),
            ("rv64.S", .riscv64, "riscv64-unknown-none-elf", ["-march=rv64gc", "-mabi=lp64d", "-mno-relax"]),
        ]

        for t in targets {
            let srcPath = "\(baseDir)/\(t.file)"
            var diags = DiagnosticBag()
            let ourObj = try Assembler.assembleFile(
                path: srcPath,
                arch: t.arch,
                includePaths: [baseDir],
                diagnostics: &diags
            )
            let errCount = diags.errorCount
            #expect(errCount == 0, "Diagnostics for \(t.file): \(errCount) errors")

            let oracleObj = try assembleWithClang(
                srcPath: srcPath,
                clangTarget: t.clangTarget,
                includePaths: [baseDir],
                extraFlags: t.extraFlags
            )
            verifyDifferentialMatch(ourObj: ourObj, oracleObj: oracleObj, context: "Todhchai \(t.file)")
        }
    }

    @Test("Differential assembly: Croi kernel (.S) across amd64, arm64, and rv64")
    func testCroiDifferentialAssembly() throws {
        let croiRoot = "/home/jkane/Projects/OS/croi"
        guard FileManager.default.fileExists(atPath: croiRoot) else { return }

        let includePaths = [
            "\(croiRoot)/kernel/include",
            "\(croiRoot)/kernel",
        ]
        let archConfigs: [(dir: String, arch: AssemblerArch, clangTarget: String, extraFlags: [String])] = [
            ("amd64", .x86_64, "x86_64-unknown-none-elf", []),
            ("arm64", .aarch64, "aarch64-unknown-none-elf", ["-march=armv8.2-a+sve"]),
            ("rv64", .riscv64, "riscv64-unknown-none-elf", ["-march=rv64gc_zba_zbb_zbs_v", "-mabi=lp64d", "-mno-relax"]),
        ]

        var assembledCount = 0
        for cfg in archConfigs {
            let archDir = "\(croiRoot)/kernel/arch/\(cfg.dir)"
            let items = (try? FileManager.default.contentsOfDirectory(atPath: archDir))?.sorted() ?? []
            for item in items where item.hasSuffix(".S") {
                let srcPath = "\(archDir)/\(item)"
                var diags = DiagnosticBag()
                let ourObj = try Assembler.assembleFile(
                    path: srcPath,
                    arch: cfg.arch,
                    includePaths: includePaths + [archDir],
                    diagnostics: &diags
                )
                let errCount = diags.errorCount
                #expect(errCount == 0, "Diagnostics for Croi \(cfg.dir)/\(item): \(errCount) errors")

                let oracleObj = try assembleWithClang(
                    srcPath: srcPath,
                    clangTarget: cfg.clangTarget,
                    includePaths: includePaths + [archDir],
                    extraFlags: cfg.extraFlags
                )
                verifyDifferentialMatch(
                    ourObj: ourObj,
                    oracleObj: oracleObj,
                    context: "Croi \(cfg.dir)/\(item)"
                )
                assembledCount += 1
            }
        }
        #expect(assembledCount == 21)
    }

    // MARK: - Helpers

    private func assembleWithClang(
        srcPath: String,
        clangTarget: String,
        includePaths: [String],
        extraFlags: [String]
    ) throws -> RelocatableObject {
        let tmpOut = "/tmp/ss_oracle_\(UUID().uuidString).o"
        defer { try? FileManager.default.removeItem(atPath: tmpOut) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        var args = ["-target", clangTarget, "-c", srcPath, "-o", tmpOut]
        for inc in includePaths {
            args.append("-I\(inc)")
        }
        args.append(contentsOf: extraFlags)
        proc.arguments = args
        try proc.run()
        proc.waitUntilExit()
        #expect(proc.terminationStatus == 0, "Clang failed on \(srcPath)")

        let bytes = Array(try Data(contentsOf: URL(fileURLWithPath: tmpOut)))
        return try ELFObjectReader.read(bytes: bytes)
    }

    private func verifyDifferentialMatch(
        ourObj: borrowing RelocatableObject,
        oracleObj: borrowing RelocatableObject,
        context: String
    ) {
        // Compare all non-empty allocatable sections (`.text`, `.text.*`, `.data`, `.rodata`, `.bss`, etc.)
        guard oracleObj.sectionCount > 0 else { return }
        for oIdx: UInt32 in 1...oracleObj.sectionCount {
            let oSec = SectionIndex(oIdx)
            let name = oracleObj.sectionName(oSec)
            let oFlags = SectionFlags(rawValue: oracleObj.sectionFlags[oSec])
            guard oFlags.contains(.alloc) else { continue }
            let oSize = oracleObj.sectionBytes[oSec].count
            if oSize == 0 { continue }

            guard let ourSec = ourObj.findSection(name: name) else {
                Issue.record("[\(context)] Missing section '\(name)' in assembled RelocatableObject")
                continue
            }

            let ourSize = ourObj.sectionBytes[ourSec].count
            #expect(ourSize == oSize, "[\(context)] Section '\(name)' size mismatch: ours=\(ourSize) vs clang=\(oSize)")

            let oKind = oracleObj.sectionKinds[oSec]
            if !oKind.isNobits && ourSize == oSize {
                let ourBytes = ourObj.sectionData(ourSec)
                let oracleBytes = oracleObj.sectionData(oSec)
                if ourBytes != oracleBytes {
                    var firstDiff = -1
                    for i in 0..<min(ourBytes.count, oracleBytes.count) where ourBytes[i] != oracleBytes[i] {
                        firstDiff = i
                        break
                    }
                    let sliceStart = max(0, firstDiff - 4)
                    let sliceEnd = min(ourBytes.count, firstDiff + 12)
                    let ourHex = ourBytes[sliceStart..<sliceEnd].map { String(format: "%02x", $0) }.joined(separator: " ")
                    let oraHex = oracleBytes[sliceStart..<sliceEnd].map { String(format: "%02x", $0) }.joined(separator: " ")
                    Issue.record("[\(context)] Section '\(name)' bytes differ at offset 0x\(String(firstDiff, radix: 16)): ours=[\(ourHex)] vs clang=[\(oraHex)]")
                }
            }
        }
    }
}

