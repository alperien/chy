#!/bin/sh
# Integration: the resolver-driven chain, built from TRANSLATED recipes.
#
# The translator replaced the hand-written zlib/libpng/freetype with
# its own output, so this checks translated recipes really build and
# run: `chy install freetype` resolves freetype's real closure (zlib,
# libpng, bzip2 here, brotli host-provided), orders it
# deterministically, builds every source recipe in a rootless prefix,
# links it through the farm. Needs a C toolchain, make, and network;
# SKIPs loudly where absent (the CI container has all three). brotli is
# the one closure member that isn't our recipe, so it plays the host
# base system: installed via xbps and declared provided, the
# provided-file model.
set -u

command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 || {
    echo "SKIP: no C toolchain"; exit 0; }
command -v make >/dev/null 2>&1 || { echo "SKIP: no make"; exit 0; }

repo=$(pwd)
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT INT TERM
CHY_ROOT="$work/root"
export CHY_ROOT

# the four recipes come from the committed golden translation,
# byte-identical to what repo-sync publishes to alperien/chy-recipes.
g="$repo/translator/tests/golden"
mkdir -p "$CHY_ROOT/recipes" "$CHY_ROOT/db"
for r in zlib libpng bzip2 freetype; do
    cp -R "$g/expected/recipes/$r" "$CHY_ROOT/recipes/"
done
# brotli and pkg-config stand in for the host base system:
# translated freetype's makedepends name both, and the container has both.
printf 'brotli\npkg-config\n' > "$CHY_ROOT/db/provided"

# the resolver's job: one requested name pulls and orders the chain,
# deterministically.
iout="$work/install.out"
sh chy/chy install freetype >"$iout" 2>"$work/install.err" || {
    echo "chain install failed"
    cat "$iout" "$work/install.err"
    exit 1
}
grep -F -x -q -- '-> order bzip2 zlib libpng freetype' "$iout" || {
    echo "missing or wrong order line; stdout was:"
    cat "$iout"
    exit 1
}
for n in zlib libpng bzip2 freetype; do
    [ -d "$CHY_ROOT/db/installed/$n" ] || { echo "not installed: $n"; exit 1; }
done

for f in usr/lib/libz.so usr/lib/libpng16.so usr/lib/libbz2.so \
         usr/lib/libfreetype.so; do
    [ -e "$CHY_ROOT/$f" ] || { echo "missing: $f"; exit 1; }
done

# runtime linking through farm + rpath: a real installed ELF must load.
out=$("$CHY_ROOT/usr/bin/pngfix" 2>&1); st=$?
if [ "$st" -eq 127 ] || printf '%s' "$out" | grep -q 'loading shared'; then
    echo "pngfix did not load: $out"; exit 1
fi

# freetype's library must resolve every NEEDED soname (brotli/bz2/png/z)
# through the farm + host, nothing dark.
if command -v ldd >/dev/null 2>&1; then
    missing=$(ldd "$CHY_ROOT/usr/lib/libfreetype.so" 2>/dev/null | grep 'not found' || :)
    [ -n "$missing" ] && { echo "unresolved:"; echo "$missing"; exit 1; }
fi

sh chy/chy list
exit 0
