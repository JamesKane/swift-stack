#!/usr/bin/env python3
"""
Generates synthetic Swift source code for benchmarking (swift-synth).
Creates a representative mix of declarations, functions, generics, closures,
and expressions.
"""

import sys
import os

def generate_swift(target_lines: int, output_path: str):
    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    
    with open(output_path, "w", encoding="utf-8") as f:
        f.write("// swift-synth benchmark corpus\n")
        f.write("// Auto-generated synthetic Swift codebase for throughput and stress tests\n\n")
        
        current_line = 3
        struct_idx = 0
        
        while current_line < target_lines:
            struct_idx += 1
            f.write(f"/// Data structure representing Node_{struct_idx}\n")
            f.write(f"public struct Record_{struct_idx}<T: Equatable & Sendable>: Sendable {{\n")
            f.write(f"    public var id: Int\n")
            f.write(f"    public var payload: T\n")
            f.write(f"    public var count: UInt32 = 0\n")
            f.write(f"    public var flags: UInt8 = 0b0000_0001\n\n")
            f.write(f"    public init(id: Int, payload: T) {{\n")
            f.write(f"        self.id = id\n")
            f.write(f"        self.payload = payload\n")
            f.write(f"    }}\n\n")
            f.write(f"    public func computeTransform(factor: Int, bias: Int) -> Int {{\n")
            f.write(f"        let temp = (id * factor) + bias\n")
            f.write(f"        if temp > 1_000_000 {{\n")
            f.write(f"            return (temp ^ 0x55AA) & 0xFFFF\n")
            f.write(f"        }} else {{\n")
            f.write(f"            return temp << 2\n")
            f.write(f"        }}\n")
            f.write(f"    }}\n\n")
            f.write(f"    public func processItems(_ items: [Int], predicate: (Int) -> Bool) -> Int {{\n")
            f.write(f"        var sum: Int = 0\n")
            f.write(f"        for item in items where predicate(item) {{\n")
            f.write(f"            sum += (item * 3) - 7\n")
            f.write(f"        }}\n")
            f.write(f"        return sum + self.computeTransform(factor: 4, bias: 10)\n")
            f.write(f"    }}\n")
            f.write(f"}}\n\n")
            
            # Each record struct block is about 28 lines
            current_line += 28

def main():
    target_lines = 10000
    if len(sys.argv) > 1:
        target_lines = int(sys.argv[1])
    
    out_file = "Benchmarks/corpora/swift-synth/synth_10k.swift"
    if len(sys.argv) > 2:
        out_file = sys.argv[2]
        
    generate_swift(target_lines, out_file)
    print(f"Generated {out_file} with target ~{target_lines} lines.")

if __name__ == '__main__':
    main()
