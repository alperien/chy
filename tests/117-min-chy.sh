#!/bin/sh
# the repo's optional min-chy marker: a repo needing a newer chy
# refuses loudly before resolution, an old or absent marker is silent.
# The marker sits beside recipes/ in the repo the symlink points at,
# and tolerates CRs like every recipe file.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# recipes/ as a symlink into a repo directory, the deployed shape
repodir="$TMPD/repodir"
mkdir -p "$repodir/recipes"
rmdir "$CHY_ROOT/recipes" 2>/dev/null || rm -rf "$CHY_ROOT/recipes"
ln -s "$repodir/recipes" "$CHY_ROOT/recipes"
mkpkg_root="$TMPD/mk"
mkpkg "$mkpkg_root" mtoy '1.0 1' usr/mtoy.txt
mv "$mkpkg_root/recipes/mtoy" "$repodir/recipes/mtoy"
mkdir -p "$CHY_ROOT/cache"
cp "$mkpkg_root/cache/"* "$CHY_ROOT/cache/"

# a repo newer than this chy refuses, naming both versions
printf '99.0.0\n' >"$repodir/min-chy"
run_chy install mtoy
assert_rc 1 'a newer repo must refuse'
file_has "$ERR" 'needs chy >= 99.0.0'

# an old marker (CR-terminated) is satisfied silently
printf '0.1.0\r\n' >"$repodir/min-chy"
run_chy install mtoy
assert_rc 0 'an old marker admits the install'
assert_installed "$CHY_ROOT" mtoy 1.0 1

# absent marker: unchanged behavior
run_chy remove mtoy
rm -f "$repodir/min-chy"
run_chy install mtoy
assert_rc 0 'no marker, no gate'

exit 0
