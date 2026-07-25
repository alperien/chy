#!/bin/sh
# outdated: read-only report, name order, of installed packages whose
# db `<version> <revision>` differs byte-wise from the recipe's
# (revision defaults to 1); it's an equality check, there's no version
# ordering. Pins `<name> <iver> <irev> -> <rver> <rrev>` on stdout,
# exit 0 always. A provided package skips with the host warning, a
# recipe-gone one with `no recipe` (both stderr). Any operand is a
# usage error (exit 2).
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- nothing installed: empty report, exit 0 ---
run_chy outdated
assert_rc 0 'empty root: outdated exits 0'
assert_empty_file "$OUT" 'nothing installed, nothing to report'
assert_empty_file "$ERR"

# --- read-only in the doctor sense: a bare root stays bare ---
rb="$TMPD/bare-root"
mkdir "$rb"
run_chy_root "$rb" outdated
assert_rc 0 'bare root: outdated exits 0'
assert_empty_file "$OUT" 'bare root: empty report'
assert_empty_file "$ERR"
for d in db usr store cache build recipes; do
    assert_absent "$rb/$d"
done
[ -z "$(ls -A "$rb")" ] || { ls -A "$rb" >&2; fail 'outdated created something in a bare root'; }

# --- any operand is a usage error: usage to stderr, exit 2 ---
run_chy outdated extra
assert_rc 2 'outdated rejects operands'
[ -s "$ERR" ] || fail 'usage expected on stderr for outdated extra'
assert_empty_file "$OUT" 'no report on a usage error'

# --- all current: installed version equals the recipe, nothing prints ---
mkpkg "$CHY_ROOT" pkg 1.0 usr/bin/pkg-tool
mkpkg "$CHY_ROOT" same 1.0 usr/bin/same-tool
run_chy install pkg same
assert_rc 0 'fixture packages install'
run_chy outdated
assert_rc 0 'all-current root: exit 0'
assert_empty_file "$OUT" 'no package differs from its recipe'
assert_empty_file "$ERR"

# --- the recipe moves to 1.1: exactly the pinned report line ---
printf '1.1\n' >"$CHY_ROOT/recipes/pkg/version"
run_chy outdated
assert_rc 0 'a differing package is still exit 0'
assert_eq "$(cat "$OUT")" 'pkg 1.0 1 -> 1.1 1' 'the one pinned report line, alone'
assert_empty_file "$ERR"

# --- the works: a revision-only bump is outdated too; provided and
#     recipe-gone packages are skipped with their warnings; the report
#     and the warnings come out in name order ---
mkpkg "$CHY_ROOT" zzz-bump 1.0 usr/bin/zzz-bump-tool
mkpkg "$CHY_ROOT" provpkg 1.0 usr/bin/provpkg-tool
mkpkg "$CHY_ROOT" gonepkg 1.0 usr/bin/gonepkg-tool
run_chy install zzz-bump provpkg gonepkg
assert_rc 0 'more fixture packages install'
printf '1.0 2\n' >"$CHY_ROOT/recipes/zzz-bump/version"
printf '9.9\n' >"$CHY_ROOT/recipes/provpkg/version"
printf 'provpkg\n' >>"$CHY_ROOT/db/provided"
rm -rf "$CHY_ROOT/recipes/gonepkg"

run_chy outdated
assert_rc 0 'warnings never change the exit status'
want=$(printf 'pkg 1.0 1 -> 1.1 1\nzzz-bump 1.0 1 -> 1.0 2')
assert_eq "$(cat "$OUT")" "$want" \
    'name-ordered report: version and revision bumps only, current package silent'
want=$(printf 'chy: gonepkg: warning: no recipe\nchy: provpkg: warning: provided by the host')
assert_eq "$(cat "$ERR")" "$want" 'skip warnings on stderr, in name order'

exit 0
