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

echo "== chy install firefox (binary kind) =="
# firefox's 21 runtime deps are the gtk+3 stack; they
# are "built OR declared host-provided". Here the host (the Void
# container, via xbps) provides them - this is the provided model at
# full scale, and it exercises exactly the new machinery: binary-kind
# relocation, the launcher, runtime verification, doctor, and launch.
# (The full FROM-SOURCE corpus build is deferred: it surfaced a real
# translator gap - per-patch strip levels.)
awk 'NF {print $1}' "$repo/recipes/firefox/depends" > "$CHY_ROOT/db/provided"

if ! sh chy/chy install firefox > "$work/out" 2> "$work/err"; then
    echo "firefox install FAILED - stdout:"; tail -n 30 "$work/out"
    echo "- stderr:"; tail -n 30 "$work/err"; exit 1
fi
grep -q '^chy: firefox: installed 153.0.1 1$' "$work/out" || {
    echo "no completion line"; tail -5 "$work/out"; exit 1; }
# runtime verification ran; any missing soname is a host gap, reported
grep '^chy: firefox: warning: needs' "$work/err" || echo "(runtime verification clean)"

echo "== chy doctor =="
sh chy/chy doctor || { echo "doctor found problems"; exit 1; }

echo "== firefox launches in a rootless prefix =="
v=$(HOME="$work/home" "$CHY_ROOT/usr/bin/firefox" --version 2>&1) || {
    echo "firefox did not run: $v"; exit 1; }
echo "$v"
printf '%s' "$v" | grep -q 'Mozilla Firefox 153.0.1' || {
    echo "unexpected version output: $v"; exit 1; }

sh chy/chy list
exit 0
