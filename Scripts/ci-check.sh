#!/usr/bin/env bash
# Scripts/ci-check.sh
# Continuous Integration gate for Swift-Stack (M0: Foundation & Measurement)
# Per docs/architecture/14-measurement-methodology.md §9 and docs/architecture/09-roadmap.md §5.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "=========================================================="
echo "  Swift-Stack CI Verification & Gating Suite             "
echo "=========================================================="

# ------------------------------------------------------------
# Gate 1: D10 Single Module Invariant
# ------------------------------------------------------------
echo "==> [Gate 1/5] Checking D10 Single Module Architecture..."
CORE_SOURCES=$(find Sources -maxdepth 1 -mindepth 1 -type d | grep -v "Sources/SwiftStack" | grep -v "Sources/Driver" | grep -v "Sources/CensusTool" | grep -v "Sources/CSupport" || true)
if [[ -n "$CORE_SOURCES" ]]; then
    echo "ERROR: D10 violation! Found fragmented targets in Sources/: $CORE_SOURCES"
    exit 1
fi
echo "PASSED: D10 invariant verified (single SwiftStack module)."

# ------------------------------------------------------------
# Gate 2: Release Build & Unit Tests
# ------------------------------------------------------------
echo ""
echo "==> [Gate 2/5] Running Release Build & Unit Test Suite..."
swift test -c release
echo "PASSED: All unit tests succeeded in release mode."

# ------------------------------------------------------------
# Gate 3: Determinism Gating (D6)
# ------------------------------------------------------------
echo ""
echo "==> [Gate 3/5] Verifying Output Determinism (D6)..."
SWIFT_STACK_BIN=".build/x86_64-unknown-linux-gnu/release/swift-stack"
CORPUS_SWIFT="Benchmarks/corpora/swift-synth/synth_50k.swift"
CORPUS_C="Benchmarks/corpora/c-synth/synth_50k.c"

if [[ ! -f "$CORPUS_SWIFT" ]]; then
    python3 Benchmarks/corpora/swift-synth/generate.py 50000 "$CORPUS_SWIFT"
fi
if [[ ! -f "$CORPUS_C" ]]; then
    python3 Benchmarks/corpora/c-synth/generate.py 50000 "$CORPUS_C"
fi

TMP_RUN1=$(mktemp)
TMP_RUN2=$(mktemp)

# Run 1 vs Run 2
"$SWIFT_STACK_BIN" --dump=tokens "$CORPUS_SWIFT" > "$TMP_RUN1"
"$SWIFT_STACK_BIN" --dump=tokens "$CORPUS_SWIFT" > "$TMP_RUN2"

if ! cmp -s "$TMP_RUN1" "$TMP_RUN2"; then
    echo "ERROR: D6 violation! Non-deterministic token dump on $CORPUS_SWIFT"
    diff -u "$TMP_RUN1" "$TMP_RUN2" | head -n 30
    rm -f "$TMP_RUN1" "$TMP_RUN2"
    exit 1
fi

"$SWIFT_STACK_BIN" --dump=tokens "$CORPUS_C" > "$TMP_RUN1"
"$SWIFT_STACK_BIN" --dump=tokens "$CORPUS_C" > "$TMP_RUN2"

if ! cmp -s "$TMP_RUN1" "$TMP_RUN2"; then
    echo "ERROR: D6 violation! Non-deterministic token dump on $CORPUS_C"
    diff -u "$TMP_RUN1" "$TMP_RUN2" | head -n 30
    rm -f "$TMP_RUN1" "$TMP_RUN2"
    exit 1
fi

# Binary executable determinism
"$SWIFT_STACK_BIN" Benchmarks/corpora/c-subset/08_recursion.c -o "$TMP_RUN1"
"$SWIFT_STACK_BIN" Benchmarks/corpora/c-subset/08_recursion.c -o "$TMP_RUN2"

if ! cmp -s "$TMP_RUN1" "$TMP_RUN2"; then
    echo "ERROR: D6 violation! Non-deterministic executable binary output on 08_recursion.c"
    rm -f "$TMP_RUN1" "$TMP_RUN2"
    exit 1
fi

rm -f "$TMP_RUN1" "$TMP_RUN2"
echo "PASSED: Output determinism (D6) verified byte-identical."

# ------------------------------------------------------------
# Gate 4: Instruction Count Gating (Perf Stat)
# ------------------------------------------------------------
echo ""
echo "==> [Gate 4/5] Checking Instruction Count Gate..."
if command -v perf >/dev/null 2>&1; then
    # Baseline for synth_50k.swift: ~126,000,000 instructions
    # Gate allows up to 3% headroom (130,000,000 instructions)
    MAX_ALLOWED_INSTRUCTIONS=130000000
    
    PERF_OUT=$(perf stat -e instructions:u "$SWIFT_STACK_BIN" "$CORPUS_SWIFT" 2>&1)
    INSN_COUNT=$(echo "$PERF_OUT" | grep "instructions:u" | awk '{print $1}' | tr -d ',')
    
    if [[ -n "$INSN_COUNT" && "$INSN_COUNT" =~ ^[0-9]+$ ]]; then
        echo "Measured retired instructions: $INSN_COUNT (Max budget: $MAX_ALLOWED_INSTRUCTIONS)"
        if (( INSN_COUNT > MAX_ALLOWED_INSTRUCTIONS )); then
            echo "ERROR: Instruction count regression! $INSN_COUNT exceeds limit $MAX_ALLOWED_INSTRUCTIONS"
            exit 1
        fi
        echo "PASSED: Instruction count within budget."
    else
        echo "WARNING: Could not parse perf instruction counter. Skipping instruction limit check."
    fi
else
    echo "WARNING: perf not found in PATH; skipping hardware instruction counter gate."
fi

# ------------------------------------------------------------
# Gate 5: Feature Census Verification
# ------------------------------------------------------------
echo ""
echo "==> [Gate 5/5] Checking Feature Census Tool (ss-census)..."
CENSUS_BIN=".build/x86_64-unknown-linux-gnu/release/ss-census"
"$CENSUS_BIN" Sources/ --markdown > /dev/null
echo "PASSED: ss-census executed successfully."

echo ""
echo "=========================================================="
echo "  All CI Gating Checks Passed Successfully!               "
echo "=========================================================="
