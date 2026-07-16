#!/bin/sh
# Integration: the acceptance chain. `chy install freetype` alone
# must resolve the repo recipes' declared depends (freetype -> zlib libpng,
# libpng -> zlib), print the deterministic order, and build the real
# packages in a fresh rootless prefix. Needs a C toolchain, make, and
# network; SKIPs loudly where absent. The CI container provides all three.
set -u

command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 || {
    echo "SKIP: no C toolchain"; exit 0; }
command -v make >/dev/null 2>&1 || { echo "SKIP: no make"; exit 0; }

repo=$(pwd)
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT INT TERM
CHY_ROOT="$work/root"
export CHY_ROOT

mkdir -p "$CHY_ROOT/recipes"
cp -R "$repo/recipes/zlib" "$repo/recipes/libpng" "$repo/recipes/freetype" \
      "$CHY_ROOT/recipes/"

# the resolver's job: one requested name pulls and orders the chain
iout="$work/install.out"
sh chy/chy install freetype >"$iout" 2>"$work/install.err" || {
    echo "chain install failed"
    cat "$iout" "$work/install.err"
    exit 1
}
grep -F -x -q 'chy: order: zlib libpng freetype' "$iout" || {
    echo "missing or wrong order line; stdout was:"
    cat "$iout"
    exit 1
}
for n in zlib libpng freetype; do
    [ -d "$CHY_ROOT/db/installed/$n" ] || { echo "not installed: $n"; exit 1; }
done

for f in usr/lib/libz.so usr/lib/libpng16.so usr/lib/libfreetype.so; do
    [ -e "$CHY_ROOT/$f" ] || { echo "missing: $f"; exit 1; }
done

# runtime linking through farm + rpath: a real installed ELF must load.
# Loader failure is exit 127 / a "loading shared libraries" complaint.
out=$("$CHY_ROOT/usr/bin/pngfix" 2>&1); st=$?
if [ "$st" -eq 127 ] || printf '%s' "$out" | grep -q 'loading shared'; then
    echo "pngfix did not load: $out"; exit 1
fi

if command -v ldd >/dev/null 2>&1; then
    missing=$(ldd "$CHY_ROOT/usr/lib/libfreetype.so" 2>/dev/null | grep 'not found' || :)
    [ -n "$missing" ] && { echo "unresolved:"; echo "$missing"; exit 1; }
fi

sh chy/chy list
exit 0
