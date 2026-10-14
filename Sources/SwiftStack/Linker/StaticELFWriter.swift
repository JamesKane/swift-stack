// Sources/SwiftStack/Linker/StaticELFWriter.swift
import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// In-process static ELF linker emitting standalone Linux x86-64 executables (06-linker.md, 09-roadmap.md §M0.5).
public struct StaticELFWriter {
    public init() {}

    public func linkAndWrite(
        functions: [EncodedFunction],
        stringLiterals: [String],
        outputPath: String
    ) throws {
        // Base virtual addresses (standard Linux 64-bit ELF layout)
        let baseVAddr: UInt64 = 0x400000
        let pageSize: UInt64 = 0x1000

        // 1. Build .rodata section (string literals)
        var rodataBytes: [UInt8] = []
        var stringOffsets: [Int: Int] = [:] // string index -> offset in rodata
        for (idx, str) in stringLiterals.enumerated() {
            stringOffsets[idx] = rodataBytes.count
            rodataBytes.append(contentsOf: str.utf8)
            rodataBytes.append(0) // null terminator
        }

        // 2. Build .text section:
        //    - _start entry stub
        //    - built-in syscall stubs (write, exit)
        //    - user functions
        var textBytes: [UInt8] = []
        var symbolVAddrs: [String: UInt64] = [:]

        // Header + Program Headers take first ~176 bytes of file/segment
        let ehdrSize = 64
        let phdrSize = 56
        let phdrCount = 2
        let textOffsetInFile = ehdrSize + phdrSize * phdrCount
        let textBaseVAddr = baseVAddr + UInt64(textOffsetInFile)

        // Hand-written _start stub (calls main, then exit syscall)
        let startSymbolOffset = textBytes.count
        symbolVAddrs["_start"] = textBaseVAddr + UInt64(startSymbolOffset)

        // _start machine code:
        // pop rdi
        textBytes.append(0x5F)
        // mov rsi, rsp
        textBytes.append(contentsOf: [0x48, 0x89, 0xE6])
        // and rsp, -16
        textBytes.append(contentsOf: [0x48, 0x83, 0xE4, 0xF0])
        // call main (rel32 placeholder)
        let callMainRelOffset = textBytes.count + 1
        textBytes.append(0xE8)
        textBytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        // mov rdi, rax
        textBytes.append(contentsOf: [0x48, 0x89, 0xC7])
        // mov rax, 60 (sys_exit)
        textBytes.append(contentsOf: [0x48, 0xC7, 0xC0, 0x3C, 0x00, 0x00, 0x00])
        // syscall
        textBytes.append(contentsOf: [0x0F, 0x05])

        // Hand-written write syscall stub:
        // write(int fd, const void *buf, size_t count) -> rax
        let writeSymbolOffset = textBytes.count
        symbolVAddrs["write"] = textBaseVAddr + UInt64(writeSymbolOffset)
        // mov rax, 1 (sys_write)
        textBytes.append(contentsOf: [0xB8, 0x01, 0x00, 0x00, 0x00])
        // syscall
        textBytes.append(contentsOf: [0x0F, 0x05])
        // ret
        textBytes.append(0xC3)

        // Hand-written exit syscall stub:
        // exit(int status)
        let exitSymbolOffset = textBytes.count
        symbolVAddrs["exit"] = textBaseVAddr + UInt64(exitSymbolOffset)
        // mov rax, 60 (sys_exit)
        textBytes.append(contentsOf: [0xB8, 0x3C, 0x00, 0x00, 0x00])
        // syscall
        textBytes.append(contentsOf: [0x0F, 0x05])

        // Append user functions
        var functionOffsets: [String: Int] = [:]
        for fn in functions {
            // 16-byte align each function
            while textBytes.count % 16 != 0 {
                textBytes.append(0x90) // nop
            }
            let fnOffset = textBytes.count
            functionOffsets[fn.name] = fnOffset
            symbolVAddrs[fn.name] = textBaseVAddr + UInt64(fnOffset)
            textBytes.append(contentsOf: fn.code)
        }

        // Layout rodata at next page boundary
        let textTotalFileSize = textOffsetInFile + textBytes.count
        let rodataOffsetInFile = Int((UInt64(textTotalFileSize) + pageSize - 1) & ~(pageSize - 1))
        let rodataBaseVAddr = baseVAddr + UInt64(rodataOffsetInFile)

        // 3. Resolve Relocations
        // Patch _start -> main
        if let mainVAddr = symbolVAddrs["main"] {
            let callInstructionNextPC = textBaseVAddr + UInt64(callMainRelOffset + 4)
            let rel32 = Int32(Int64(mainVAddr) - Int64(callInstructionNextPC))
            patchInt32(&textBytes, at: callMainRelOffset, value: rel32)
        }

        // Patch function relocations
        for fn in functions {
            guard let fnBaseOffset = functionOffsets[fn.name] else { continue }
            for reloc in fn.relocations {
                let patchOffset = fnBaseOffset + reloc.offset
                let nextPC = textBaseVAddr + UInt64(patchOffset + 4)

                if reloc.isStringRef {
                    let strOff = stringOffsets[reloc.stringIndex] ?? 0
                    let targetVAddr = rodataBaseVAddr + UInt64(strOff)
                    let rel32 = Int32(Int64(targetVAddr) - Int64(nextPC))
                    patchInt32(&textBytes, at: patchOffset, value: rel32)
                } else {
                    let targetVAddr = symbolVAddrs[reloc.symbol] ?? (textBaseVAddr + UInt64(writeSymbolOffset))
                    let rel32 = Int32(Int64(targetVAddr) - Int64(nextPC))
                    patchInt32(&textBytes, at: patchOffset, value: rel32)
                }
            }
        }

        // 4. Construct complete ELF binary file
        var fileBytes: [UInt8] = []

        // --- ELF Header (64 bytes) ---
        // e_ident
        fileBytes.append(contentsOf: [
            0x7F, 0x45, 0x4C, 0x46, // \x7F ELF
            0x02,                   // 2 = 64-bit
            0x01,                   // 1 = Little Endian
            0x01,                   // 1 = Current ELF version
            0x00,                   // 0 = System V ABI
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 // Padding
        ])
        appendUInt16(&fileBytes, 0x0002) // e_type: ET_EXEC
        appendUInt16(&fileBytes, 0x003E) // e_machine: EM_X86_64
        appendUInt32(&fileBytes, 0x00000001) // e_version: 1
        appendUInt64(&fileBytes, symbolVAddrs["_start"] ?? textBaseVAddr) // e_entry
        appendUInt64(&fileBytes, 0x40)   // e_phoff: 64 (immediately follows ELF header)
        appendUInt64(&fileBytes, 0x00)   // e_shoff: 0 (no section headers needed for static execution)
        appendUInt32(&fileBytes, 0x00)   // e_flags: 0
        appendUInt16(&fileBytes, 64)     // e_ehsize: 64
        appendUInt16(&fileBytes, 56)     // e_phentsize: 56
        appendUInt16(&fileBytes, UInt16(phdrCount)) // e_phnum: 2
        appendUInt16(&fileBytes, 0)      // e_shentsize: 0
        appendUInt16(&fileBytes, 0)      // e_shnum: 0
        appendUInt16(&fileBytes, 0)      // e_shstrndx: 0

        // --- Program Headers (56 bytes each) ---
        // Phdr 0: PT_LOAD for .text (R + X)
        appendUInt32(&fileBytes, 0x01) // p_type: PT_LOAD
        appendUInt32(&fileBytes, 0x05) // p_flags: PF_R | PF_X
        appendUInt64(&fileBytes, 0x00) // p_offset
        appendUInt64(&fileBytes, baseVAddr) // p_vaddr
        appendUInt64(&fileBytes, baseVAddr) // p_paddr
        appendUInt64(&fileBytes, UInt64(textTotalFileSize)) // p_filesz
        appendUInt64(&fileBytes, UInt64(textTotalFileSize)) // p_memsz
        appendUInt64(&fileBytes, pageSize) // p_align: 4096

        // Phdr 1: PT_LOAD for .rodata (R)
        appendUInt32(&fileBytes, 0x01) // p_type: PT_LOAD
        appendUInt32(&fileBytes, 0x04) // p_flags: PF_R
        appendUInt64(&fileBytes, UInt64(rodataOffsetInFile)) // p_offset
        appendUInt64(&fileBytes, rodataBaseVAddr) // p_vaddr
        appendUInt64(&fileBytes, rodataBaseVAddr) // p_paddr
        appendUInt64(&fileBytes, UInt64(rodataBytes.count)) // p_filesz
        appendUInt64(&fileBytes, UInt64(rodataBytes.count)) // p_memsz
        appendUInt64(&fileBytes, pageSize) // p_align: 4096

        // Append text bytes
        fileBytes.append(contentsOf: textBytes)

        // Pad to rodata offset
        while fileBytes.count < rodataOffsetInFile {
            fileBytes.append(0)
        }

        // Append rodata bytes
        fileBytes.append(contentsOf: rodataBytes)

        // 5. Write binary to disk and chmod +x
        let data = Data(fileBytes)
        try data.write(to: URL(fileURLWithPath: outputPath))
        chmod(outputPath, 0o755)
    }

    private func patchInt32(_ bytes: inout [UInt8], at offset: Int, value: Int32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { p in
            for i in 0..<4 {
                bytes[offset + i] = p[i]
            }
        }
    }

    private func appendUInt16(_ bytes: inout [UInt8], _ val: UInt16) {
        var v = val.littleEndian
        withUnsafeBytes(of: &v) { p in
            bytes.append(contentsOf: p)
        }
    }

    private func appendUInt32(_ bytes: inout [UInt8], _ val: UInt32) {
        var v = val.littleEndian
        withUnsafeBytes(of: &v) { p in
            bytes.append(contentsOf: p)
        }
    }

    private func appendUInt64(_ bytes: inout [UInt8], _ val: UInt64) {
        var v = val.littleEndian
        withUnsafeBytes(of: &v) { p in
            bytes.append(contentsOf: p)
        }
    }
}
