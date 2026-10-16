// Sources/SwiftStack/Codegen/X86/X86AsmPrinter.swift
//
// Writes allocated LIR and a module's data as AT&T assembly, which Swift-Stack's assembler (or any other) turns into
// an object file. Instructions go through the encoder's `X86Instruction`, so their text is what the assembler and
// disassembler share.

import Foundation

struct X86AsmPrinter {
    let ctx: X86ModuleContext
    var out = ""

    init(ctx: X86ModuleContext) { self.ctx = ctx }

    static func quoted(_ name: String) -> String {
        let plain = name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "$" } && !(name.first?.isNumber ?? true)
        return plain ? name : "\"\(name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    func symbolName(_ s: UInt32) -> String { Self.quoted(ctx.symbols[s]) }

    static func blockLabel(function: Int, block: Int) -> String { ".LBB\(function)_\(block)" }

    // MARK: - Functions

    mutating func print(function f: LIRFunction, index: Int, symbol: AIRSymbol) {
        let name = Self.quoted(f.name)
        out += "\t.text\n"
        if symbol.linkage == .external { out += "\t.globl\t\(name)\n" }
        out += "\t.p2align\t4, 0x90\n"
        out += "\t.type\t\(name),@function\n"
        out += "\(name):\n"
        out += "\t.cfi_startproc\n"
        for b in f.blocks.indices {
            // A block reached only by falling through needs no label, but labels are free; every block gets one
            if b > 0 { out += Self.blockLabel(function: index, block: b) + ":\n" }
            let insts = f.blocks[b].insts
            var k = 0
            while k < insts.count {
                let inst = insts[k]
                // `jcc next; jmp other` becomes `j!cc other`; a jump to the next block is left out
                if inst.op == .jcc, k + 1 < insts.count, insts[k + 1].op == .jmp,
                   blockTarget(f, inst) == b + 1 {
                    var inverted = inst
                    inverted.cond = inst.cond.inverted
                    inverted.firstOperand = insts[k + 1].firstOperand
                    line(f, inverted, index)
                    k += 2
                    continue
                }
                if inst.op == .jmp, blockTarget(f, inst) == b + 1, k == insts.count - 1 {
                    k += 1
                    continue
                }
                line(f, inst, index)
                k += 1
            }
        }
        out += ".Lfunc_end\(index):\n"
        out += "\t.size\t\(name), .Lfunc_end\(index)-\(name)\n"
        out += "\t.cfi_endproc\n"
        // Constants and jump tables
        for c in f.constants {
            out += "\t.section\t.rodata,\"a\",@progbits\n"
            out += "\t.p2align\t\(log2(c.alignment))\n"
            out += "\(symbolName(c.label)):\n"
            out += "\t.byte\t" + c.bytes.map { "\($0)" }.joined(separator: ",") + "\n"
        }
        for (k, table) in f.jumpTables.enumerated() {
            let label = ".LJTI\(index)_\(k)"
            out += "\t.section\t.rodata,\"a\",@progbits\n"
            out += "\t.p2align\t2\n"
            out += "\(label):\n"
            for t in table { out += "\t.long\t\(Self.blockLabel(function: index, block: t))-\(label)\n" }
        }
    }

    func log2(_ n: Int) -> Int { n <= 1 ? 0 : Int.bitWidth - 1 - n.leadingZeroBitCount }

    func blockTarget(_ f: LIRFunction, _ inst: LIRInst) -> Int? {
        let o = f.operands[Int(inst.firstOperand)]
        return o.kind == .block ? Int(o.value) : nil
    }

    mutating func line(_ f: LIRFunction, _ inst: LIRInst, _ index: Int) {
        if let text = text(f, inst, index) { out += "\t" + text + "\n" }
    }

    func x86(_ o: LIROperand, _ index: Int) -> X86Operand? {
        switch o.kind {
        case .none: return nil
        case .reg: return .reg(o.reg.physical.x86Reg(size: Int(o.size)))
        case .imm:
            if o.symbol != 0 { return .imm(o.value, symbol: symbolName(o.symbol) + o.modifier.suffix) }
            return .imm(o.value)
        case .mem:
            if o.isBlockAddress {
                return .mem(.ripRelative(symbol: Self.blockLabel(function: index, block: Int(o.value))))
            }
            let base: X86Reg? = o.reg.isNone ? (o.symbol != 0 && o.index.isNone && o.segment == 0 ? .rip : nil) : o.reg.physical.x86Reg(size: 8)
            let indexReg: X86Reg? = o.index.isNone ? nil : o.index.physical.x86Reg(size: 8)
            let symbol = o.symbol != 0 ? symbolName(o.symbol) + o.modifier.suffix : nil
            return .mem(X86Mem(segment: o.segment == 0 ? nil : o.segment, base: base, index: indexReg, scale: o.scale, disp: o.value,
                               symbol: symbol, forceDisp32: base == .rip))
        case .block: return .relTarget(0, symbol: Self.blockLabel(function: index, block: Int(o.value)))
        case .symbol: return .relTarget(0, symbol: symbolName(o.symbol) + o.modifier.suffix)
        }
    }

    func text(_ f: LIRFunction, _ inst: LIRInst, _ index: Int) -> String? {
        let ops = f.operands[inst.operandRange].filter { !$0.isImplicit }
        let size = Int(inst.size)
        switch inst.op {
        case .entry, .callFrameSetup, .callFrameDestroy:
            return nil
        case .cfi:
            let kind = ops[0].value, reg = PhysReg(rawValue: UInt8(ops[1].value))!, offset = ops[2].value
            switch kind {
            case 0: return ".cfi_def_cfa_offset \(offset)"
            case 1: return ".cfi_offset %\(reg.name(size: 8)), \(offset)"
            default: return ".cfi_def_cfa_register %\(reg.name(size: 8))"
            }
        case .inlineAsm:
            return X86InlineAsm.text(f, inst, function: index, printer: self)
        case .zero:
            let r = ops[0].reg.physical
            if r.isXMM { return "xorps %\(r.name(size: 16)), %\(r.name(size: 16))" }
            return "movl $0, %\(r.name(size: 4))"
        case .copy:
            let d = ops[0].reg.physical, s = ops[1].reg.physical
            if d.isXMM || s.isXMM {
                if d.isXMM && s.isXMM { return "movaps %\(s.name(size: 16)), %\(d.name(size: 16))" }
                return d.isXMM ? "movq %\(s.name(size: 8)), %\(d.name(size: 16))" : "movq %\(s.name(size: 16)), %\(d.name(size: 8))"
            }
            let sz = size == 8 ? 8 : 4
            return (sz == 8 ? "movq" : "movl") + " %\(s.name(size: sz)), %\(d.name(size: sz))"
        case .fld, .fstp:
            return "\(inst.op) %st(\(ops[0].value))"
        case .fucomip, .fucomi:
            return "\(inst.op) %st(1), %st"
        case .faddp, .fsubp, .fsubrp, .fmulp, .fdivp, .fdivrp:
            return "\(inst.op) %st, %st(1)"
        case .fxch:
            return "fxch %st(1)"
        case .callIndirect, .jmpIndirect:
            let target: X86Operand
            switch ops[0].kind {
            case .reg: target = .indirectReg(ops[0].reg.physical.x86Reg(size: 8))
            default:
                guard case .mem(let m)? = x86(ops[0], index) else { return nil }
                target = .indirectMem(m)
            }
            return X86Instruction(mnemonic: inst.op.mnemonic(size: 8, cond: inst.cond), operands: [target]).attString
        default:
            let operands = ops.reversed().compactMap { x86($0, index) }
            return X86Instruction(mnemonic: inst.op.mnemonic(size: size, cond: inst.cond), operands: operands,
                                  lockPrefix: inst.lock).attString
        }
    }

    // MARK: - Data

    mutating func print(object s: AIRSymbol, functions: [LIRFunction]) {
        let name = Self.quoted(X86ModuleContext.asmName(s))
        let image = s.image
        let zero = image?.isZero ?? true
        let section: String
        if s.isThreadLocal {
            section = zero ? ".section\t.tbss,\"awT\",@nobits" : ".section\t.tdata,\"awT\",@progbits"
        } else if zero && !s.isConstant {
            section = ".bss"
        } else if s.isConstant {
            section = (image?.relocations.isEmpty ?? true) ? ".section\t.rodata,\"a\",@progbits" : ".section\t.data.rel.ro,\"aw\",@progbits"
        } else {
            section = ".data"
        }
        out += "\t\(section)\n"
        if s.linkage == .external { out += "\t.globl\t\(name)\n" }
        out += "\t.type\t\(name),@object\n"
        out += "\t.p2align\t\(log2(max(1, s.alignment)))\n"
        out += "\(name):\n"
        let size = max(s.size, 1)
        if zero {
            out += "\t.zero\t\(size)\n"
        } else if let image {
            var pos = 0
            let relocs = image.relocations.sorted { $0.offset < $1.offset }
            func bytes(_ upTo: Int) {
                var k = pos
                while k < upTo {
                    if k >= image.bytes.count {
                        out += "\t.zero\t\(upTo - k)\n"
                        break
                    }
                    // A run of zeros as .zero when it is long or ends the range; other bytes 16 to a line
                    var z = k
                    while z < upTo && z < image.bytes.count && image.bytes[z] == 0 { z += 1 }
                    if z > k && (z - k >= 8 || z == upTo || z == image.bytes.count) {
                        out += "\t.zero\t\(z - k)\n"
                        k = z
                        continue
                    }
                    let end = min(upTo, k + 16, image.bytes.count)
                    out += "\t.byte\t" + image.bytes[k..<end].map { "\($0)" }.joined(separator: ",") + "\n"
                    k = end
                }
                pos = upTo
            }
            for r in relocs {
                bytes(r.offset)
                let target: String
                switch r.target {
                case .symbol(let t): target = Self.quoted(X86ModuleContext.asmName(ctx.module.symbols[t]))
                case .block(let fn, let b):
                    let lirBlock = fn < functions.count && Int(b.rawIndex) < functions[fn].airBlockMap.count
                        ? functions[fn].airBlockMap[Int(b.rawIndex)] : 0
                    target = Self.blockLabel(function: fn, block: lirBlock)
                }
                let value = r.addend == 0 ? target : r.addend > 0 ? "\(target)+\(r.addend)" : "\(target)\(r.addend)"
                out += "\t\(r.size == 8 ? ".quad" : r.size == 4 ? ".long" : r.size == 2 ? ".short" : ".byte")\t\(value)\n"
                pos = r.offset + r.size
            }
            bytes(size)
        }
        out += "\t.size\t\(name), \(size)\n"
    }
}

/// Code generation for x86-64: each function selected, allocated and laid out, then the module written as assembly.
public enum X86CodeGenerator {
    public struct Result {
        public var assembly: String
        public var issues: [String]
        public var functions: [LIRFunction]
    }

    public static func generate(_ module: AIRModule, verifyAllocation: Bool = false) -> Result {
        let ctx = X86ModuleContext(module: module)
        var issues: [String] = []
        var lirFunctions: [LIRFunction] = []
        for k in module.functions.indices {
            let isel = X86FunctionISel(ctx: ctx, function: k)
            let selected = isel.run()
            issues += isel.issues
            let allocator = LinearScan(selected)
            var allocated = allocator.run()
            issues += allocator.issues
            if verifyAllocation { issues += allocator.conflicts().map { "\(selected.name): \($0)" } }
            var frame = X86FrameLowering()
            frame.run(&allocated)
            issues += frame.issues
            lirFunctions.append(allocated)
        }
        var printer = X86AsmPrinter(ctx: ctx)
        for line in module.moduleAsm { printer.out += line + "\n" }
        for (k, f) in lirFunctions.enumerated() {
            printer.print(function: f, index: k, symbol: module.symbols[module.functions[k].function.symbol])
        }
        for s in module.symbols where s.kind == .object && s.linkage != .undefined {
            printer.print(object: s, functions: lirFunctions)
        }
        printer.out += "\t.section\t\".note.GNU-stack\",\"\",@progbits\n"
        return Result(assembly: printer.out, issues: issues, functions: lirFunctions)
    }
}
