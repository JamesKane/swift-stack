#!/usr/bin/env bash
# Benchmarks/run-benchmarks.sh
# Runs B1 lexing benchmarks and records baselines per docs/architecture/14-measurement-methodology.md

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "=========================================================="
echo "  Swift-Stack Benchmark Runner (Milestone 0: B1 Lexing)  "
echo "=========================================================="

# 1. Build release binaries
echo "==> Building swift-stack in release mode..."
swift build -c release

SWIFT_STACK_BIN=".build/x86_64-unknown-linux-gnu/release/swift-stack"
SWIFT_SYNTH_CORPUS="Benchmarks/corpora/swift-synth/synth_50k.swift"
C_SYNTH_CORPUS="Benchmarks/corpora/c-synth/synth_50k.c"

# 2. Ensure corpora exist
if [[ ! -f "$SWIFT_SYNTH_CORPUS" ]]; then
    echo "==> Generating swift-synth corpus..."
    python3 Benchmarks/corpora/swift-synth/generate.py 50000 "$SWIFT_SYNTH_CORPUS"
fi

if [[ ! -f "$C_SYNTH_CORPUS" ]]; then
    echo "==> Generating c-synth corpus..."
    python3 Benchmarks/corpora/c-synth/generate.py 50000 "$C_SYNTH_CORPUS"
fi

echo ""
echo "==> Corpus Statistics (non-blank, non-comment lines):"
./Benchmarks/count-lines "$SWIFT_SYNTH_CORPUS" "$C_SYNTH_CORPUS"

echo ""
echo "=========================================================="
echo "  1. Swift Lexing Benchmark (B1)                          "
echo "=========================================================="
echo "--- Swift-Stack (SwiftLexer Repetition Tester) ---"
"$SWIFT_STACK_BIN" --bench "$SWIFT_SYNTH_CORPUS"

echo ""
echo "--- swiftc Baseline (swiftc -frontend -dump-parse) ---"
if command -v perf >/dev/null 2>&1; then
    perf stat -e instructions:u,cpu-cycles:u swiftc -frontend -dump-parse "$SWIFT_SYNTH_CORPUS" > /dev/null
else
    time swiftc -frontend -dump-parse "$SWIFT_SYNTH_CORPUS" > /dev/null
fi

echo ""
echo "=========================================================="
echo "  2. ISO C23 Lexing Benchmark (B1)                        "
echo "=========================================================="
echo "--- Swift-Stack (CLexer Repetition Tester) ---"
"$SWIFT_STACK_BIN" --bench "$C_SYNTH_CORPUS"

echo ""
echo "--- Clang Baseline (clang -std=c23 -E) ---"
if command -v perf >/dev/null 2>&1; then
    perf stat -e instructions:u,cpu-cycles:u clang -std=c23 -E "$C_SYNTH_CORPUS" > /dev/null
else
    time clang -std=c23 -E "$C_SYNTH_CORPUS" > /dev/null
fi

echo ""
echo "=========================================================="
echo "  Benchmark Run Complete                                  "
echo "=========================================================="
