import Foundation
import Testing
@testable import SwiftStack

// The `swift-stack` driver passes its target options to the assembler as clang's driver passes them to its integrated
// assembler (05-assembler.md §4.13): each case assembles a `.s` or `.S` file with `DriverOptions.parse` and
// `DriverPipeline` (the code `swift-stack` runs) and with `clang -c`, given the same arguments, and compares the
// objects exactly (`ExactObjectComparison`). Skipped when clang is absent.

struct DriverAssemblerCase: CustomTestStringConvertible, Sendable {
    let source: String
    let triple: String
    let flags: [String]
    var testDescription: String { "\(triple) \(source) \(flags.joined(separator: " "))" }
}

enum DriverAssemblerCorpus {
    static let sources: [String: String] = [
        // `la` (a GOT load when PIC), a call, compressible instructions, `li` of a single high bit (`bseti` with
        // Zbs), alignment padding and a branch across it (relaxation relocations), data.
        "rv.s": """
            .text
            .globl f
        f:
            la a0, sym
            call g
            addi a0, a0, 1
            li a1, 0x100000000000
            .p2align 3
            beq a0, a1, 1f
            nop
        1:  ret
            .data
            .quad sym
        """,
        "rv.S": """
        #ifdef WIDE
        #define STEP 16
        #else
        #define STEP 8
        #endif
            .text
            .globl h
        h:
            addi sp, sp, -STEP
            la t0, tbl
            ld t1, 0(t0)
            addi sp, sp, STEP
            ret
            .section .rodata
        tbl: .quad h
        """,
        // GOT loads LLVM MC marks relaxable, and one it does not.
        "x86.s": """
            .text
            .globl f
        f:
            movq sym@GOTPCREL(%rip), %rax
            addq other@GOTPCREL(%rip), %rax
            call *g@GOTPCREL(%rip)
            jmp *h@GOTPCREL(%rip)
            movq %fs:0, %rdx
            ret
        """,
        "a64.s": """
            .text
            .globl f
        f:
            adrp x0, :got:sym
            ldr x0, [x0, :got_lo12:sym]
            add x0, x0, #1
            ret
        """,
    ]

    static var cases: [DriverAssemblerCase] {
        var out: [DriverAssemblerCase] = []
        let bare = "riscv64-unknown-none-elf"
        for flags: [String] in [
            [], ["-march=rv64gc", "-mabi=lp64d"], ["-march=rv64imac_zicsr_zifencei", "-mabi=lp64", "-mno-relax"],
            ["-march=rv64gc_zba_zbb_zbs"], ["-mabi=lp64"], ["-march=rv64imaf"], ["-march=rv64gc", "-mabi=lp64f"],
            ["-fPIC"], ["-fPIC", "-fno-pic"], ["-fPIE", "-mno-relax"], ["-mno-relax", "-mrelax"], ["-Wa,--noexecstack"],
        ] {
            out.append(DriverAssemblerCase(source: "rv.s", triple: bare, flags: flags))
        }
        for flags: [String] in [[], ["-fPIE"], ["-march=rv64gcv"]] {
            out.append(DriverAssemblerCase(source: "rv.s", triple: "riscv64-unknown-linux-gnu", flags: flags))
        }
        for flags: [String] in [[], ["-DWIDE", "-march=rv64imac_zicsr_zifencei", "-mabi=lp64", "-mno-relax"], ["-fPIC", "-march=rv64gc"]] {
            out.append(DriverAssemblerCase(source: "rv.S", triple: bare, flags: flags))
        }
        for flags: [String] in [
            [], ["-Wa,-mrelax-relocations=no"], ["-Wa,--mrelax-relocations=no", "-Wa,-mrelax-relocations=yes"],
            ["-Wa,--noexecstack,-mrelax-relocations=no"], ["-march=x86-64-v3", "-fPIC"],
        ] {
            out.append(DriverAssemblerCase(source: "x86.s", triple: "x86_64-unknown-none-elf", flags: flags))
        }
        for flags: [String] in [[], ["-march=armv8.2-a"], ["-Wa,--noexecstack"], ["-fPIE"]] {
            out.append(DriverAssemblerCase(source: "a64.s", triple: "aarch64-unknown-none-elf", flags: flags))
        }
        return out
    }
}

@Suite("M2 — Driver target options reach the assembler as in clang")
struct M2DriverAssemblerTests {

    @Test("swift-stack -c <file.s|.S> with target options matches clang -c (exact)",
          .enabled(if: ExternalTool.referenceClang != nil), arguments: DriverAssemblerCorpus.cases)
    func driverMatchesClang(_ c: DriverAssemblerCase) throws {
        let clang = try #require(ExternalTool.referenceClang)
        let dir = ExternalTool.temporaryPath("-driver")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let src = "\(dir)/\(c.source)", ours = "\(dir)/ours.o", ref = "\(dir)/clang.o"
        try DriverAssemblerCorpus.sources[c.source]!.write(toFile: src, atomically: true, encoding: .utf8)

        let r = try ExternalTool.run(clang, ["--target=\(c.triple)"] + c.flags + ["-c", src, "-o", ref])
        try #require(r.status == 0, "clang -c failed: \(r.stderr)")

        let (options, warnings) = DriverOptions.parse(["--target=\(c.triple)"] + c.flags + ["-c", src, "-o", ours])
        #expect(warnings.isEmpty, Comment(rawValue: warnings.joined(separator: "\n")))
        let status = try DriverPipeline(options: options).run()
        try #require(status == 0, "swift-stack failed on \(c.testDescription)")

        let diffs = ExactObjectComparison.differences(ours: try TestELF(path: ours), oracle: try TestELF(path: ref))
        #expect(diffs.isEmpty, Comment(rawValue: "\(c.testDescription):\n  " + diffs.prefix(30).joined(separator: "\n  ")))
    }

    @Test("Driver option parsing: clang's defaults and last-wins rules for the RISC-V assembler state")
    func riscvDefaults() {
        func rv(_ args: [String]) -> RVAsmOptions { DriverOptions.parse(args).options.riscvAssemblerOptions }
        // Bare metal: rv64imac/lp64 with relaxation; another OS: rv64imafdc/lp64d; an lp64* ABI alone: rv64imafdc.
        #expect(rv(["--target=riscv64-unknown-none-elf"]).targetArchAttribute == "rv64i2p1_m2p0_a2p1_c2p0_zmmul1p0_zaamo1p0_zalrsc1p0_zca1p0")
        #expect(rv(["--target=riscv64-unknown-none-elf"]).elfFlags == 0x1)
        #expect(rv(["--target=riscv64-unknown-linux-gnu"]).elfFlags == 0x5)
        #expect(rv(["--target=riscv64-unknown-none-elf", "-mabi=lp64"]).elfFlags == 0x1)
        #expect(rv(["--target=riscv64-unknown-none-elf", "-mabi=lp64"]).targetArchAttribute?.contains("_d2p2_") == true)
        #expect(rv(["--target=riscv64-unknown-none-elf"]).relaxEnabled)
        #expect(!rv(["--target=riscv64-unknown-none-elf", "-mrelax", "-mno-relax"]).relaxEnabled)
        #expect(rv(["--target=riscv64-unknown-none-elf", "-fno-pie", "-fPIC"]).picEnabled)
        #expect(!rv(["--target=riscv64-unknown-linux-gnu"]).picEnabled)
        let (x86, warnings) = DriverOptions.parse(["-target", "x86_64-linux-gnu", "-Wa,--noexecstack,--mrelax-relocations=no", "-Wa,-bogus", "t.s"])
        #expect(x86.targetArch == .x86_64 && x86.inputFiles == ["t.s"])
        #expect(x86.assemblerOptions.noExecStack && !x86.assemblerOptions.x86RelaxRelocations)
        #expect(warnings == ["unsupported assembler option '-bogus' in '-Wa,-bogus'"])
    }
}
