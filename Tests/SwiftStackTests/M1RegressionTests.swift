import Foundation
import Testing
@testable import SwiftStack

// Regressions for M1 front-end defects found in review: each test pins one fixed behavior.

@Suite("M1 — Front-end regressions")
struct M1RegressionTests {

    private static func writeTemp(_ source: String, ext: String = ".c") throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("ss_m1_\(UUID().uuidString)\(ext)").path
        try source.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// Compiles and runs a program through the driver; returns its exit status.
    private static func compileAndRun(_ source: String, includePaths: [String] = []) throws -> Int32 {
        let src = try writeTemp(source)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("ss_m1_bin_\(UUID().uuidString)").path
        defer {
            try? FileManager.default.removeItem(atPath: src)
            try? FileManager.default.removeItem(atPath: out)
        }
        var opts = DriverOptions()
        opts.inputFiles = [src]
        opts.includePaths = includePaths
        opts.outputBinaryPath = out
        opts.runBinary = true
        return try DriverPipeline(options: opts).run()
    }

    private static func accepts(_ source: String) throws -> Bool {
        let path = try writeTemp(source)
        defer { try? FileManager.default.removeItem(atPath: path) }
        return try CFrontendCheck.run(path: path).accepted
    }

    @Test("Macros defined in headers or predefined lower to their values, not 0")
    func macroValuesFromOtherBuffers() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ss_m1_inc_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "#define N 42\n".write(to: dir.appendingPathComponent("n.h"), atomically: true, encoding: .utf8)
        #expect(try Self.compileAndRun("#include \"n.h\"\nint main(void) { return N; }\n", includePaths: [dir.path]) == 42)
        #expect(try Self.compileAndRun("#include <limits.h>\nint main(void) { return CHAR_BIT + __SIZEOF_INT__; }\n") == 12)
    }

    @Test("`##` re-lexes its result; an invalid paste is an error")
    func tokenPasting() throws {
        #expect(try Self.compileAndRun("#define cat(a,b) a##b\nint main(void) { int a = 1; a cat(+,=) 2; return a; }\n") == 3)
        #expect(try Self.compileAndRun("#define cat(a,b) a##b\nint main(void) { int foobar = 5; return cat(foo,bar); }\n") == 5)
        #expect(try !Self.accepts("#define cat(a,b) a##b\nint f(void) { return cat(.,.); }\n"))
    }

    @Test("Compound assignment operators are lowered (not treated as `=`)")
    func compoundAssignment() throws {
        #expect(try Self.compileAndRun("int main(void) { int a = 10; a -= 3; a *= 2; a <<= 1; a |= 1; return a; }\n") == 29)
    }

    @Test("Multi-word type specifiers resolve to the right type")
    func multiWordTypeSpecifiers() throws {
        #expect(try Self.accepts("""
        _Static_assert(sizeof(unsigned char) == 1, "uc");
        _Static_assert(sizeof(unsigned short) == 2, "us");
        _Static_assert(sizeof(unsigned long long) == 8, "ull");
        _Static_assert(sizeof(long double) == 16, "ld");
        _Static_assert(sizeof(const unsigned volatile char) == 1, "cuvc");
        _Static_assert(sizeof(int long) == 8, "il");
        typedef char size_t;
        _Static_assert(sizeof(size_t) == 1, "user typedef wins");
        """))
        #expect(try !Self.accepts("_Static_assert(sizeof(unsigned char) == 4, \"must fail\");\n"))
    }

    @Test("Syntax errors anywhere in the tree are rejected (not only at the root)")
    func syntaxErrorsRejected() throws {
        for bad in [
            "int f(void) { int x = 1 + ; return 0; }",
            "int f(void) { return (; }",
            "int f(int x) { if x) return 1; return 0; }",
            "int f(void) { return 0 }",
            "struct S { 123 abc +; int a; };",
            "enum E { A, 3, B };",
        ] {
            #expect(try !Self.accepts(bad + "\n"), "accepted: \(bad)")
        }
        for good in [
            "void f(int x) { if (x) { lbl: } switch (x) { case 1: } }",
            "void f(void) { static_assert(1); }",
            "int f(int a, int b) { return a ? : b; }",
            "typedef int T; void f(void) { int T = 2, x = 3; (void)(T * x); }",
            "struct S { int a[4]; int b; }; struct S s = { .a[2] = 5, .b = 1 };",
            "void f(void) { __asm__ volatile(\"nop\" ::: \"memory\"); }",
        ] {
            #expect(try Self.accepts(good + "\n"), "rejected: \(good)")
        }
    }

    @Test("Core type-checking constraints are diagnosed")
    func constraintViolationsRejected() throws {
        for bad in [
            "struct S { int a; }; void f(void) { struct S s; int i; i = s; }",
            "int g(int); void f(void) { g(1, 2); }",
            "void f(void) { int x; x(); }",
            "void f(void) { break; }",
            "void f(int x) { switch (x) { case 1: case 1: break; } }",
            "void f(void) { int x; int x; }",
            "int x = 1; int x = 2;",
            "void f(void) { 3++; }",
            "void f(void) { const int x = 1; x = 2; }",
            "void f(void) { int *p; p = 5; }",
            "void f(void) { return 1; }",
            "void f(void) { goto nowhere; }",
            "int g(void); void f(void) { static int x = g(); }",
            "void f(double d) { (void)(d % 2); }",
        ] {
            #expect(try !Self.accepts(bad + "\n"), "accepted: \(bad)")
        }
    }

    @Test("`#if` arithmetic follows intmax_t/uintmax_t rules and never traps")
    func preprocessorArithmetic() throws {
        #expect(try Self.accepts("""
        #if !(-1 > 0u)
        #error "unsigned conversion"
        #endif
        #if '\\n' != 10 || '\\377' != -1 || 'ab' != 24930 || '\\x41' != 65
        #error "character constants"
        #endif
        #if (-9223372036854775807-1) / -1 != (-9223372036854775807-1)
        #error "INT64_MIN / -1 wraps"
        #endif
        #if 0 && (1/0)
        #error "short circuit"
        #endif
        int ok;
        """))
        #expect(try !Self.accepts("#if 1/0\n#endif\nint ok;\n"))
    }

    @Test("`#include <...>` names are not macro-expanded")
    func includeNamesNotExpanded() throws {
        #expect(try Self.accepts("#include <errno.h>\n#include <errno.h>\nint f(void) { return errno; }\n"))
    }

    @Test("SWAR whitespace skipping keeps a `!` that follows indentation")
    func lexerKeepsBangAfterIndentation() throws {
        for indent in 1...16 {
            let pad = String(repeating: " ", count: indent)
            #expect(try Self.accepts("int f(int s, int t) { return ((s & 1)\n\(pad)!=(t == 0)); }\n"), "indent \(indent)")
        }
        #expect(try Self.compileAndRun("int main(void) { int a = 1, b = 0;\n    if (a &&\n        !b) return 7;\n    return 3; }\n") == 7)
        // The exact-per-byte zero test: a 0x01 byte above a zero byte must not be flagged
        #expect(SWAR.hasZeroByte(0x0000_0000_0000_0100) == 0x8080_8080_8080_0080)
        #expect(SWAR.horizontalSpaceRun(0x2020_2020_3D21_2020) == 2)
    }

    @Test("VectraOS C: nullability qualifiers, attributes in declarators, `__INT64_C`, directives in macro arguments")
    func vectraOSConstructs() throws {
        // Clang's nullability qualifiers, on every pointer of VectraOS's kernel headers (Swift's importer reads them)
        #expect(try Self.accepts("""
        void f(const void *_Nullable regs, int *_Nonnull out, char *_Null_unspecified s, void *_Nullable_result *r);
        void cpuid(unsigned leaf, unsigned out[_Nonnull 4]);
        int (*_Nullable handler)(int);
        int call(void) { return handler ? handler(1) : 0; }
        """))
        // A GNU attribute inside a parenthesized declarator still declares a function pointer (efi.h's EFIAPI)
        #expect(try Self.accepts("""
        typedef struct P P;
        struct P { int (__attribute__((ms_abi)) *Out)(P *self, int x); };
        static inline int call(P *p) { return p->Out(p, 1); }
        int (__attribute__((ms_abi)) *g)(int);
        int use(void) { return g(1); }
        """))
        // Clang's predefined integer-constant macros, which its freestanding <stdint.h> uses for `UINT64_C`
        #expect(try Self.accepts("""
        #if !defined(__INT64_C_SUFFIX__) || __UINT64_C(5) != 5 || __INT32_C(-3) != -3
        #error "integer constant macros"
        #endif
        unsigned long big = __UINT64_C(18446744073709551615);
        """))
        // `#if` inside a function-like macro's arguments (usertest.c's `CHECK(...)`), as GCC and Clang process it
        #expect(try Self.accepts("""
        #define CHECK(n, cond) int check##n(void) { return (cond); }
        CHECK(1, 1 ==
        #if defined(__x86_64__)
                 1
        #else
                 undeclared_identifier
        #endif
        )
        """))
    }

    @Test("Shared C literal decoding")
    func literalDecoding() {
        #expect(CLiteral.characterValue("'\\n'") == 10)
        #expect(CLiteral.characterValue("'\\0'") == 0)
        #expect(CLiteral.characterValue("'\\377'") == -1)
        #expect(CLiteral.characterValue("'ab'") == 0x6162)
        #expect(CLiteral.characterValue("u'\\xFF'") == 255)
        #expect(CLiteral.integerValue("0xFFFFFFFFFFFFFFFF")! == (UInt64.max, true))
        #expect(CLiteral.integerValue("10u")! == (10, true))
        #expect(CLiteral.integerValue("1'000'000")! == (1_000_000, false))
        #expect(CLiteral.integerValue("255uwb")! == (255, true))
        #expect(CLiteral.stringBytes("a\\tb\\101\\x42") == [0x61, 0x09, 0x62, 0x41, 0x42])
        #expect(CLiteral.stringBytes("\\351é") == [0xE9, 0xC3, 0xA9])
    }
}
