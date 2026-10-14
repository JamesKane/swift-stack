#!/usr/bin/env python3
"""
Generates synthetic ISO C23 source code for benchmarking (c-synth).
Creates a representative mix of declarations, structs, constexpr,
pointers, and expressions.
"""

import sys
import os

def generate_c(target_lines: int, output_path: str):
    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    
    with open(output_path, "w", encoding="utf-8") as f:
        f.write("/* c-synth benchmark corpus */\n")
        f.write("/* Auto-generated synthetic ISO C23 codebase for throughput tests */\n\n")
        f.write("#include <stdint.h>\n")
        f.write("#include <stdbool.h>\n\n")
        
        current_line = 6
        struct_idx = 0
        
        while current_line < target_lines:
            struct_idx += 1
            f.write(f"/* Component {struct_idx} */\n")
            f.write(f"typedef struct Component_{struct_idx} {{\n")
            f.write(f"    int64_t id;\n")
            f.write(f"    uint32_t flags;\n")
            f.write(f"    double value;\n")
            f.write(f"    struct Component_{struct_idx} *next;\n")
            f.write(f"}} Component_{struct_idx}_t;\n\n")
            
            f.write(f"[[nodiscard]] static inline int64_t transform_{struct_idx}(Component_{struct_idx}_t *comp, int64_t bias) {{\n")
            f.write(f"    if (!comp) return -1;\n")
            f.write(f"    auto temp = comp->id * 1'000 + bias;\n")
            f.write(f"    constexpr bool kFastPath = true;\n")
            f.write(f"    if constexpr (kFastPath) {{\n")
            f.write(f"        return (temp ^ 0b1010'1100) + (int64_t)comp->value;\n")
            f.write(f"    }} else {{\n")
            f.write(f"        return temp >> 1;\n")
            f.write(f"    }}\n")
            f.write(f"}}\n\n")
            
            f.write(f"int run_batch_{struct_idx}(Component_{struct_idx}_t *head, int count) {{\n")
            f.write(f"    int processed = 0;\n")
            f.write(f"    Component_{struct_idx}_t *curr = head;\n")
            f.write(f"    while (curr != nullptr && processed < count) {{\n")
            f.write(f"        curr->id = transform_{struct_idx}(curr, processed);\n")
            f.write(f"        curr = curr->next;\n")
            f.write(f"        processed++;\n")
            f.write(f"    }}\n")
            f.write(f"    return processed;\n")
            f.write(f"}}\n\n")
            
            current_line += 27

def main():
    target_lines = 10000
    if len(sys.argv) > 1:
        target_lines = int(sys.argv[1])
    
    out_file = "Benchmarks/corpora/c-synth/synth_10k.c"
    if len(sys.argv) > 2:
        out_file = sys.argv[2]
        
    generate_c(target_lines, out_file)
    print(f"Generated {out_file} with target ~{target_lines} lines.")

if __name__ == '__main__':
    main()
