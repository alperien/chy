#!/bin/sh
# conflicts are found on the normalized tree before store or farm is
# touched, so the whole install links or none of it does. File paths
# owned by another package, and directory paths occupied by anything
# that isn't a real directory, are conflicts. Ownership is string
# equality on the whole component after store/ ("foo" never owns
# "foo-bar").
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- file-shaped conflict: names path and owner, links nothing ---
mkpkg "$CHY_ROOT" pkga 1.0 usr/bin/clash usr/bin/onlya
run_chy install pkga
assert_rc 0 'pkga install'

mkpkg "$CHY_ROOT" pkgb 1.0 usr/bin/aab usr/bin/clash usr/bin/onlyb
snap0=$(snap "$CHY_ROOT")
run_chy install pkgb
assert_rc 1 'conflicting file path fails the install'
file_has "$ERR" 'usr/bin/clash'
file_has "$ERR" 'pkga'
assert_eq "$(snap "$CHY_ROOT")" "$snap0" 'nothing linked, store and db untouched'
assert_absent "$CHY_ROOT/usr/bin/aab"
assert_absent "$CHY_ROOT/usr/bin/onlyb"
assert_not_installed "$CHY_ROOT" pkgb
assert_no_store "$CHY_ROOT" pkgb 1.0
assert_eq "$(cat "$CHY_ROOT/usr/bin/clash")" \
    "$(pkg_content pkga usr/bin/clash)" 'pkga still owns the path'

# --- directory-shaped conflict: needed dir occupied by a symlink ---
mkpkg "$CHY_ROOT" dirown 1.0 usr/libexec/tool
run_chy install dirown
assert_rc 0 'dirown install'
mkpkg "$CHY_ROOT" dirneed 1.0 usr/libexec/tool/helper
snap0=$(snap "$CHY_ROOT")
run_chy install dirneed
assert_rc 1 'needed directory path occupied by a file is a conflict'
file_has "$ERR" 'usr/libexec/tool'
file_has "$ERR" 'dirown'
assert_eq "$(snap "$CHY_ROOT")" "$snap0" 'directory conflict links nothing'
assert_not_installed "$CHY_ROOT" dirneed

# --- ownership exactness: foo must not own foo-bar's links, nor reverse ---
mkpkg "$CHY_ROOT" foo 1.0 usr/bin/foo-own
mkpkg "$CHY_ROOT" foo-bar 1.0 usr/bin/foobar-own
run_chy install foo foo-bar
assert_rc 0 'foo and foo-bar coexist'

# foo v1.1 tries to take foo-bar's path: conflict, old foo stays intact
mkpkg "$CHY_ROOT" foo 1.1 usr/bin/foo-own usr/bin/foobar-own
snap0=$(snap "$CHY_ROOT")
run_chy install foo
assert_rc 1 'foo may not replace a link owned by foo-bar'
file_has "$ERR" 'usr/bin/foobar-own'
assert_eq "$(snap "$CHY_ROOT")" "$snap0" 'failed reinstall left everything intact'
assert_installed "$CHY_ROOT" foo 1.0 1
assert_link "$CHY_ROOT/usr/bin/foobar-own" '../../store/foo-bar/usr/bin/foobar-own'

# foo-bar v1.1 tries to take foo's path: conflict the other way around
mkpkg "$CHY_ROOT" foo-bar 1.1 usr/bin/foobar-own usr/bin/foo-own
snap0=$(snap "$CHY_ROOT")
run_chy install foo-bar
assert_rc 1 'foo-bar may not replace a link owned by foo'
file_has "$ERR" 'usr/bin/foo-own'
assert_eq "$(snap "$CHY_ROOT")" "$snap0" 'reverse case also left intact'
assert_installed "$CHY_ROOT" foo-bar 1.0 1
assert_link "$CHY_ROOT/usr/bin/foo-own" '../../store/foo/usr/bin/foo-own'

# --- a same-owner leftover link is not a conflict; silently replaced ---
mkpkg "$CHY_ROOT" selfy 1.0 usr/bin/selftool
mkdir -p "$CHY_ROOT/usr/bin"
ln -s '../../store/selfy/usr/bin/selftool' "$CHY_ROOT/usr/bin/selftool"
run_chy install selfy
assert_rc 0 'crash-recovery idempotence: own dangling link replaced'
assert_link "$CHY_ROOT/usr/bin/selftool" '../../store/selfy/usr/bin/selftool'
assert_eq "$(cat "$CHY_ROOT/usr/bin/selftool")" \
    "$(pkg_content selfy usr/bin/selftool)" 'replaced link resolves'

# --- a plain user file on a needed file path is a conflict ---
mkpkg "$CHY_ROOT" vic 1.0 usr/bin/victim
printf 'user data\n' >"$CHY_ROOT/usr/bin/victim"
snap0=$(snap "$CHY_ROOT")
run_chy install vic
assert_rc 1 'a non-symlink occupant is a conflict'
file_has "$ERR" 'usr/bin/victim'
assert_eq "$(snap "$CHY_ROOT")" "$snap0" 'conflict left the user file alone'
assert_eq "$(cat "$CHY_ROOT/usr/bin/victim")" 'user data' 'user file untouched'
assert_not_installed "$CHY_ROOT" vic

# --- registry files are normalized away, never owned: two packages
#     both staging usr/share/info/dir (every GNU make install does)
#     must not conflict, and the file must not reach the store ---
mkpkg "$CHY_ROOT" infoa '1.0 1' usr/bin/infoa usr/share/info/dir \
    usr/lib/charset.alias
mkpkg "$CHY_ROOT" infob '1.0 1' usr/bin/infob usr/share/info/dir
run_chy install infoa
assert_rc 0 'first info-staging package installs'
run_chy install infob
assert_rc 0 'second info-staging package must not conflict on info/dir'
assert_installed "$CHY_ROOT" infoa 1.0 1
assert_installed "$CHY_ROOT" infob 1.0 1
assert_absent "$CHY_ROOT/usr/share/info/dir"
assert_absent "$CHY_ROOT/usr/lib/charset.alias"

exit 0
