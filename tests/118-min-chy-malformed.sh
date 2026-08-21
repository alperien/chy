#!/bin/sh
# the repo's optional min-chy marker, malformed-marker arm: a marker
# chy cannot read as a version refuses the install (fail closed) and
# names the offending content. A silent skip would be exactly the
# old-repo misread the gate exists to prevent.
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

snap0=$(snap "$CHY_ROOT")

# garbage marker: refuse loudly, name the content
printf 'hello world\n' >"$repodir/min-chy"
run_chy install mtoy
assert_rc 1 'a malformed marker must refuse'
file_has_line "$ERR" 'chy: error: malformed min-chy: hello world'

# empty marker file: same refusal, (empty) named
: >"$repodir/min-chy"
run_chy install mtoy
assert_rc 1 'an empty marker must refuse'
file_has_line "$ERR" 'chy: error: malformed min-chy: (empty)'

# refused before any work: root untouched
assert_eq "$(snap "$CHY_ROOT")" "$snap0" 'malformed markers leave the root as it was'

exit 0
