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
    # content comparison, mode-agnostic: the corpus reaches git hosts
    # with API-normalized modes while fresh emission sets exec bits
    if python3 - "$g/expected" "$tmp" <<'PYCMP'
import filecmp, os, sys
a, b = sys.argv[1], sys.argv[2]
def walk(root):
    out = {}
    for d, _, fs in os.walk(root):
        for f in fs:
            p = os.path.join(d, f)
            out[os.path.relpath(p, root)] = p
    return out
fa, fb = walk(a), walk(b)
bad = sorted(set(fa) ^ set(fb))
for rel in sorted(set(fa) & set(fb)):
    if not filecmp.cmp(fa[rel], fb[rel], shallow=False):
        bad.append(rel)
if bad:
    print("differs:", " ".join(bad[:6]))
    sys.exit(1)
PYCMP
    then
        echo "PASS golden: corpus twenty byte-exact"
    else
        echo "FAIL golden: corpus differs from expected"
        exit 1
    fi
fi
