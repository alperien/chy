#!/bin/sh
# 510: the chytrans black-box suite.
#
# Thin harness entry: the real work lives in translator/tests/run, a
# python3-stdlib runner over committed synthetic snapshot fixtures. Skips
# loudly while the prerequisites are missing - python3 arrives via the
# container prepare step, translator/chytrans via the build
# waves - and never weakens: once the translator exists, every fixture
# must pass.
set -eu
cd "$(dirname "$0")/.." || exit 2

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
[ -f translator/chytrans ] || { echo "SKIP: translator not present"; exit 0; }

python3 translator/tests/run || exit 1

# --- the corpus golden: live-snapshotted twenty ------
g=translator/tests/golden
if [ -d "$g/snapshot" ]; then
    tmp=$(mktemp -d) || exit 1
    trap 'rm -rf "$tmp"' EXIT INT TERM
    mkdir -p "$tmp/recipes"
    cp -R "$g/expected/recipes/bzip2" "$tmp/recipes/"
    # shellcheck disable=SC2046
    if ! python3 translator/chytrans translate --snapshot "$g/snapshot" \
            --out "$tmp" $(cat "$g/names") >/dev/null 2>&1; then
        echo "FAIL golden: translate exited nonzero"; exit 1
    fi
    if git diff --no-index --quiet "$g/expected" "$tmp"; then
        echo "PASS golden: corpus twenty byte-exact"
    else
        echo "FAIL golden: corpus differs from expected"
        git diff --no-index --stat "$g/expected" "$tmp" | tail -5
        exit 1
    fi
fi
