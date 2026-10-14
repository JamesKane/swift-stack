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
}

