#!/bin/sh
# The corpus acceptance, in one script.
#
# Heavy by design: builds the FULL translated corpus closure from source
# by asking for one thing - firefox - whose depends pull gtk+3, which
# pulls everything else. Then: the drift check (built ELF
# NEEDED vs each recipe's expect-needed ledger), chy doctor, and the
# the payoff: Mozilla's binary launching in a rootless prefix.
#
# Gated: run only when CHY_CORPUS=1 (the CI corpus job sets it); the
# regular suite SKIPs it loudly. Expects the host packages listed in
# tests/corpus-hostpkgs (the Void container installs them).
set -u

[ "${CHY_CORPUS:-}" = 1 ] || { echo "SKIP: CHY_CORPUS not set"; exit 0; }
for t in cc make readelf python3; do
    command -v "$t" >/dev/null 2>&1 || { echo "corpus: missing $t"; exit 1; }
done

repo=$(pwd)
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT INT TERM
CHY_ROOT="$work/root"
export CHY_ROOT

mkdir -p "$CHY_ROOT/db"
cp -R "$repo/recipes" "$CHY_ROOT/recipes"
cp "$repo/shlibs.map" "$CHY_ROOT/shlibs.map"
# provided = everything the corpus closure needs that we do not build:
# the first column of provided.suggested, plus firefox's manual extras.
awk 'NF {print $1}' "$repo/provided.suggested" > "$CHY_ROOT/db/provided"
printf 'alsa-lib\ngcc\n' >> "$CHY_ROOT/db/provided"

echo "== chy install firefox =="
if ! sh chy/chy install firefox > "$work/out" 2> "$work/err"; then
    echo "corpus install FAILED - stdout tail:"
    tail -n 40 "$work/out"
    echo "- stderr tail:"
    tail -n 40 "$work/err"
    exit 1
fi
grep '^chy: order: ' "$work/out"
if grep '^chy: .*: warning: needs' "$work/err"; then
    echo "unexpected runtime-verification warnings above"; exit 1
fi

echo "== drift check: built NEEDED vs expect-needed =="
python3 - "$CHY_ROOT" <<'PYDRIFT' || { echo "DRIFT DETECTED"; exit 1; }
import os, re, struct, subprocess, sys
root = sys.argv[1]

def needed(path):
    with open(path, 'rb') as f: d = f.read(16)
    if d[:4] != b'\x7fELF': return None
    out = subprocess.run(['readelf', '-d', path], capture_output=True, text=True)
    return re.findall(r'\(NEEDED\).*\[(.*)\]', out.stdout)

bad = 0
for n in sorted(os.listdir(os.path.join(root, 'db', 'installed'))):
    meta = os.path.join(root, 'recipes', n, 'meta')
    if not os.path.isfile(meta): continue
    text = open(meta).read()
    expect = set(re.findall(r'^expect-needed: (.*)$', text, re.M))
    if not expect or 'kind: binary' in text: continue # vendor ELFs verified at authoring
    store = os.path.join(root, 'store', n)
    actual, own = set(), set()
    for d, _, fs in os.walk(store, followlinks=True):
        for f in fs:
            p = os.path.join(d, f)
            if os.path.islink(p):
                if '.so' in f: own.add(f)
                continue
            if '.so' in f: own.add(f)
            ns = needed(p)
            if ns: actual.update(ns)
    for s_ in sorted(actual - own - expect):
        print(f"+{n} needs {s_} (not in expect-needed)"); bad += 1
    for s_ in sorted(expect - actual):
        print(f"-{n} expected {s_} (not linked)"); bad += 1
sys.exit(1 if bad else 0)
PYDRIFT
echo "no drift: every built package links exactly what Void's record says"

echo "== chy doctor =="
sh chy/chy doctor || { echo "doctor found problems"; exit 1; }

echo "== firefox launches in a rootless prefix =="
v=$(HOME="$work/home" "$CHY_ROOT/usr/bin/firefox" --version 2>&1) || {
    echo "firefox did not run: $v"; exit 1; }
echo "$v"
printf '%s' "$v" | grep -q 'Mozilla Firefox 153.0.1' || {
    echo "unexpected version output"; exit 1; }

sh chy/chy list
exit 0
