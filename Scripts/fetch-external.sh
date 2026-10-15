#!/usr/bin/env bash
# Scripts/fetch-external.sh
# Fetches pinned third-party test inputs into External/ (09-roadmap.md §4.2: fetched, never committed).
# The differential tests skip any corpus that is absent.

set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXT="$ROOT_DIR/External"
mkdir -p "$EXT"

# name | repository | pinned commit
fetch() {
    local name=$1 url=$2 commit=$3
    local dest="$EXT/$name"
    if [[ -d "$dest/.git" ]] && [[ "$(git -C "$dest" rev-parse HEAD)" == "$commit" ]]; then
        echo "$name: already at $commit"
        return
    fi
    rm -rf "$dest"
    git init -q "$dest"
    git -C "$dest" remote add origin "$url"
    git -C "$dest" fetch -q --depth 1 origin "$commit"
    git -C "$dest" checkout -q FETCH_HEAD
    echo "$name: fetched $commit"
}

# c-testsuite: M1 accept/reject exit criterion (Tests/SwiftStackTests/M1DifferentialTests.swift)
fetch c-testsuite https://github.com/c-testsuite/c-testsuite.git 5c7275656d751de0e68b2d340a95b5681858ed07
