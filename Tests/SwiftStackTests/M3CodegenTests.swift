import Foundation
import Testing
@testable import SwiftStack

// M3 phase 3 gates (milestones/M3-plan.md §2): x86-64 code generation on every corpus (selection, allocation with
// its interference check, frame layout, and the assembly assembled by Swift-Stack's assembler), and c-testsuite's
// programs compiled, linked by ld.lld and run.

enum CodegenCheck {
    /// Generates x86-64 code for a corpus file and assembles it: the issues, at most 8.
    static func check(_ file: CCorpusFile) throws -> [String] {
        if let arch = file.target?.arch, arch != "x86_64" { return [] }
        try CCorpora.prepare(file)
        let outcome = try CFrontendCheck.run(path: file.path, includePaths: file.includePaths, target: file.target)
        guard outcome.accepted, let module = outcome.module else { return [] }
        let lowering = AIRLowering.lower(module)
        guard lowering.issues.isEmpty else { return [] }
        let generated = X86CodeGenerator.generate(lowering.module, verifyAllocation: true)
        var issues = Array(generated.issues.prefix(8))
        var diagnostics = DiagnosticBag()
        let sm = SourceManager()
        _ = Assembler.assemble(source: generated.assembly, arch: .x86_64, fileName: file.path + ".s", sourceManager: sm,
                               diagnostics: &diagnostics)
        if diagnostics.errorCount > 0 {
            issues.append("assembler: " + DiagnosticRenderer.render(diagnostics: diagnostics, sourceManager: sm).split(separator: "\n").prefix(6).joined(separator: "\n"))
        }
        return issues
    }
}

/// Programs whose results differ for reasons outside code generation, each with its cause.
let knownCodegenExceptions: [String: String] = [
    "00209.c": "calls `int (*)()` with an argument, which C23 (6.7.7.4) rejects as clang -std=c23 does",
    "b15_complex_ok.c": "_Complex is not supported (02 §4.2.6)",
]

@Suite("M3 — x86-64 code generation on the C corpora")
struct M3CodegenCorpusTests {
    static func check(_ file: CCorpusFile) throws {
        let issues = try CodegenCheck.check(file)
        if knownCodegenExceptions[URL(fileURLWithPath: file.path).lastPathComponent] != nil { return }
        #expect(issues.isEmpty, "\(file.testDescription): \(issues.joined(separator: "\n"))")
    }

    @Test("Constraint probes", arguments: CCorpora.acceptReject)
    func probes(_ file: CCorpusFile) throws { try Self.check(file) }

    @Test("SQLite amalgamation", .enabled(if: !CCorpora.sqlite.isEmpty), arguments: CCorpora.sqlite)
    func sqlite(_ file: CCorpusFile) throws { try Self.check(file) }

    @Test("Lua 5.4 sources", .enabled(if: !CCorpora.lua.isEmpty), arguments: CCorpora.lua)
    func lua(_ file: CCorpusFile) throws { try Self.check(file) }

    @Test("VectraOS C sources (x86-64)", .enabled(if: CCorpora.vectraOS.count == 36), arguments: CCorpora.vectraOS)
    func vectraOS(_ file: CCorpusFile) throws { try Self.check(file) }
}

/// Compiles C programs with the driver and runs them.
enum ProgramRunner {
    static let scratch: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ss_m3_run_\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Compiles `path` to an executable (linked with `extraObjects`); nil and the first problem if it fails.
    static func compile(_ path: String, includePaths: [String] = [], extraObjects: [String] = []) throws -> (binary: String?, message: String) {
        let outcome = try CFrontendCheck.run(path: path, includePaths: includePaths)
        guard outcome.accepted, let module = outcome.module else { return (nil, outcome.firstError) }
        let lowering = AIRLowering.lower(module)
        guard lowering.issues.isEmpty else { return (nil, lowering.issues.prefix(3).map { "\($0)" }.joined(separator: "\n")) }
        let generated = X86CodeGenerator.generate(lowering.module, verifyAllocation: true)
        guard generated.issues.isEmpty else { return (nil, generated.issues.prefix(3).joined(separator: "\n")) }
        var diagnostics = DiagnosticBag()
        let sm = SourceManager()
        let object = Assembler.assemble(source: generated.assembly, arch: .x86_64, fileName: path + ".s", sourceManager: sm,
                                        diagnostics: &diagnostics)
        guard diagnostics.errorCount == 0 else {
            return (nil, DiagnosticRenderer.render(diagnostics: diagnostics, sourceManager: sm))
        }
        let binary = scratch.appendingPathComponent(UUID().uuidString).path
        let objectPath = binary + ".o"
        try Data(ELFObjectWriter.write(object)).write(to: URL(fileURLWithPath: objectPath))
        defer { try? FileManager.default.removeItem(atPath: objectPath) }
        let status = DriverPipeline.link(objects: [objectPath] + extraObjects, output: binary, libraries: [])
        return status == 0 ? (binary, "") : (nil, "link failed: \(status)")
    }

    /// Runs a program with a time limit: its exit status (or -1 on timeout) and its standard output.
    static func run(_ binary: String, arguments: [String] = [], timeout: Double = 10) throws -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        // In a directory of its own: some programs write files (c-testsuite's 00187 writes fred.txt)
        let workDir = scratch.appendingPathComponent("cwd_" + UUID().uuidString)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        process.currentDirectoryURL = workDir
        let outPath = scratch.appendingPathComponent(UUID().uuidString + ".out").path
        FileManager.default.createFile(atPath: outPath, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: outPath) }
        let handle = FileHandle(forWritingAtPath: outPath)
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(2000) }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? handle?.close()
        let output = (try? Data(contentsOf: URL(fileURLWithPath: outPath))) ?? Data()
        if Date() >= deadline { return (-1, output) }
        return (process.terminationStatus, output)
    }
}

@Suite("M3 — c-testsuite programs compiled and run")
struct M3ExecutionTests {
    @Test("c-testsuite single-exec programs", .enabled(if: CCorpora.hasClang && !CCorpora.cTestsuite.isEmpty),
          arguments: CCorpora.cTestsuite)
    func cTestsuite(_ file: CCorpusFile) throws {
        let name = URL(fileURLWithPath: file.path).lastPathComponent
        if knownCodegenExceptions[name] != nil { return }
        let (binary, message) = try ProgramRunner.compile(file.path)
        guard let binary else {
            Issue.record("\(name) does not compile: \(message.prefix(400))")
            return
        }
        defer { try? FileManager.default.removeItem(atPath: binary) }
        let (status, output) = try ProgramRunner.run(binary)
        let expected = (try? Data(contentsOf: URL(fileURLWithPath: file.path + ".expected"))) ?? Data()
        #expect(status == 0, "\(name) exits with \(status)")
        #expect(output == expected, "\(name) prints \(String(decoding: output.prefix(300), as: UTF8.self))")
    }
}

/// Real programs built by Swift-Stack: Lua 5.4.7 running its own test suite, and the SQLite shell running a SQL
/// workload against a clang-built shell. The sources are fetched into `External/` (as c-testsuite is); without them
/// the tests are skipped.
@Suite("M3 — Lua and SQLite built by Swift-Stack")
struct M3ProgramTests {
    static var luaDir: String { CCorpora.repoTests.deletingLastPathComponent().appendingPathComponent("External/lua").path }
    static var hasLua: Bool {
        FileManager.default.fileExists(atPath: luaDir + "/lua-5.4.7/src/lua.c") && FileManager.default.fileExists(atPath: luaDir + "/lua-5.4.7-tests/all.lua")
    }

    @Test("Lua 5.4.7 passes its test suite", .enabled(if: CCorpora.hasClang && hasLua))
    func lua() throws {
        let src = Self.luaDir + "/lua-5.4.7/src"
        let dir = ProgramRunner.scratch.appendingPathComponent("lua_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var objects: [String] = []
        for file in CCorpora.cFiles(in: src) where !file.hasSuffix("/luac.c") {
            let out = dir.appendingPathComponent(URL(fileURLWithPath: file).lastPathComponent + ".o").path
            let (object, message) = try M3ABITests.ownObject(file, includePaths: [src], defines: [("LUA_USE_POSIX", "1")], output: out)
            guard let object else {
                Issue.record("\(file): \(message.prefix(400))")
                return
            }
            objects.append(object)
        }
        let binary = dir.appendingPathComponent("lua").path
        try #require(M3ABITests.link(objects, binary), "Lua does not link")
        // The suite runs from its own directory
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-e_U=true", "all.lua"]
        process.currentDirectoryURL = URL(fileURLWithPath: Self.luaDir + "/lua-5.4.7-tests")
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: output, as: UTF8.self)
        #expect(process.terminationStatus == 0 && text.contains("final OK"), "Lua's suite: \(text.suffix(600))")
    }

    static var sqliteDir: String? {
        guard let file = CCorpora.sqlite.first?.path else { return nil }
        let dir = URL(fileURLWithPath: file).deletingLastPathComponent().path
        return FileManager.default.fileExists(atPath: dir + "/shell.c") ? dir : nil
    }

    @Test("The SQLite shell runs a SQL workload as clang's does", .enabled(if: CCorpora.hasClang && sqliteDir != nil))
    func sqlite() throws {
        let src = try #require(Self.sqliteDir)
        let dir = ProgramRunner.scratch.appendingPathComponent("sqlite_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var objects: [String] = []
        for name in ["sqlite3.c", "shell.c"] {
            let out = dir.appendingPathComponent(name + ".o").path
            let (object, message) = try M3ABITests.ownObject(src + "/" + name, includePaths: [src], defines: [("_GNU_SOURCE", "1")], output: out)
            guard let object else {
                Issue.record("\(name): \(message.prefix(400))")
                return
            }
            objects.append(object)
        }
        let ours = dir.appendingPathComponent("sqlite3").path
        try #require(M3ABITests.link(objects, ours), "SQLite does not link")
        let reference = dir.appendingPathComponent("sqlite3-clang").path
        let clang = Process()
        clang.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        clang.arguments = ["clang", "-O0", "-w", "-D_GNU_SOURCE", "-I\(src)", src + "/sqlite3.c", src + "/shell.c", "-o", reference, "-lm"]
        try clang.run()
        clang.waitUntilExit()
        try #require(clang.terminationStatus == 0)
        let sql = """
        create table a(id integer primary key, name text, v real, n int);
        with recursive c(i) as (select 1 union all select i+1 from c where i<20000)
        insert into a(name,v,n) select 'n'||(i*7919%1000), i*1.0/7, (i*2654435761)%100003 from c;
        create index ia on a(name);
        create table b as select n%97 k, count(*) cnt, sum(v) sv, min(name) mn, max(n) mx from a group by n%97;
        select count(*), sum(v), avg(n), total(v*v), min(name), max(name) from a;
        select k, cnt, round(sv,6), mn, mx from b order by k;
        select a.name, b.cnt from a join b on a.n%97=b.k where a.id%500=0 order by a.id;
        select name, count(*) from a group by name having count(*)>6 order by 2 desc, 1 limit 25;
        select id, v, sum(v) over (order by id rows 3 preceding), rank() over (partition by n%5 order by v desc) from a where id<200 order by id;
        select json_object('a',1,'b',json_array(1,2.5,'x')), json_extract('{"x":[1,{"y":3}]}','$.x[1].y');
        select upper('hello'), substr('abcdef',2,3), replace('aaa','a','bc'), instr('hello','ll'), quote(1.25e300), hex(zeroblob(3));
        select 1e308*10, -0.0, 5%3, -5%3, 7/2, 7.0/2, cast('12abc' as int), cast(3.99 as int), 9223372036854775807+1;
        select printf('%.20g %e %10.4f|%-8s|%08d', 0.1, 12345.678, -2.5, 'ab', -42);
        select datetime(1700000000,'unixepoch'), julianday('2024-02-29'), strftime('%j %W','2024-12-31');
        select group_concat(id) from (select id from a where name='n7' order by id);
        update a set v = v * 2 where id % 3 = 0;
        delete from a where id % 7 = 0;
        select count(*), sum(v), max(id) from a;
        pragma integrity_check;
        """
        let script = dir.appendingPathComponent("work.sql").path
        try sql.write(toFile: script, atomically: true, encoding: .utf8)
        func run(_ binary: String) throws -> Data {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: binary)
            p.standardInput = FileHandle(forReadingAtPath: script)
            let pipe = Pipe()
            p.standardOutput = pipe
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return data
        }
        let mine = try run(ours), theirs = try run(reference)
        #expect(!mine.isEmpty && mine == theirs, "SQLite output differs:\n\(String(decoding: mine.prefix(800), as: UTF8.self))")
    }
}
