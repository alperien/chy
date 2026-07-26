#!/bin/sh
# remove: names in order, a not-installed name is an error (exit 1,
# stop there). Manifest paths missing or replaced get a stderr warning
# and are left alone (exit still 0). Emptied dirs are pruned, never
# $CHY_ROOT's top-level entries. Alias, store entry and db entry all
# go. Pins the completion line exactly.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- not installed: exit 1 ---
run_chy remove ghost
assert_rc 1 'removing a package that is not installed fails'
file_matches "$ERR" '^chy: ghost: error: '

# --- stop there: names after the failing one are not processed ---
mkpkg "$CHY_ROOT" r1 1.0 usr/bin/r1-tool
run_chy install r1
assert_rc 0 'r1 install'
run_chy remove ghost r1
assert_rc 1 'error name stops the run'
assert_installed "$CHY_ROOT" r1 1.0 1
assert_eq "$(cat "$CHY_ROOT/usr/bin/r1-tool")" \
    "$(pkg_content r1 usr/bin/r1-tool)" 'r1 survives the aborted remove'

# --- happy removal: exact completion line, pruning, top-level survives ---
mkpkg "$CHY_ROOT" rr '1.5 2' usr/bin/rr-tool usr/share/doc/rr/README
run_chy install rr
assert_rc 0 'rr install'
run_chy remove rr
assert_rc 0 'remove exits 0'
file_has_line "$OUT" '- rr 1.5_2'
if grep -v '^-> rr ' "$OUT" | grep -q -v '^- rr '; then
    cat "$OUT" >&2
    fail 'stdout carries a line outside the -> rr / - rr grammar'
fi
assert_empty_file "$ERR" 'clean removal warns about nothing'
assert_absent "$CHY_ROOT/usr/bin/rr-tool"
assert_absent "$CHY_ROOT/usr/share"
[ -d "$CHY_ROOT/usr" ] || fail 'top-level usr/ must never be pruned'
[ -d "$CHY_ROOT/usr/bin" ] || fail 'usr/bin still holds r1, must stay'
assert_no_store "$CHY_ROOT" rr 1.5
assert_not_installed "$CHY_ROOT" rr
run_chy list rr
assert_rc 1 'removed package is no longer installed'

# --- warnings: missing and user-replaced paths, exit still 0 ---
mkpkg "$CHY_ROOT" rw 1.0 usr/bin/w1 usr/bin/w2 usr/bin/w3
run_chy install rw
assert_rc 0 'rw install'
rm "$CHY_ROOT/usr/bin/w1"
rm "$CHY_ROOT/usr/bin/w2"
printf 'user data\n' >"$CHY_ROOT/usr/bin/w2"
run_chy remove rw
assert_rc 0 'warnings never affect exit status'
file_has_line "$OUT" '- rw 1.0_1'
assert_eq "$(count_matches '^chy: rw: warning: ' "$ERR")" '2' \
    'one warning per missing or replaced path'
assert_eq "$(cat "$CHY_ROOT/usr/bin/w2")" 'user data' 'replaced file left alone'
assert_absent "$CHY_ROOT/usr/bin/w3"
[ -d "$CHY_ROOT/usr/bin" ] || fail 'usr/bin still holds the user file'
assert_no_store "$CHY_ROOT" rw 1.0
assert_not_installed "$CHY_ROOT" rw

# --- multiple names in order; shared dirs pruned only when empty ---
mkpkg "$CHY_ROOT" ra 1.0 usr/libexec/chyx/ra-tool
mkpkg "$CHY_ROOT" rb 1.0 usr/libexec/chyx/rb-tool
run_chy install ra rb
assert_rc 0 'ra and rb install'
run_chy remove ra
assert_rc 0 'remove ra alone'
assert_absent "$CHY_ROOT/usr/libexec/chyx/ra-tool"
[ -d "$CHY_ROOT/usr/libexec/chyx" ] || fail 'shared dir must survive while rb owns a link'
assert_eq "$(cat "$CHY_ROOT/usr/libexec/chyx/rb-tool")" \
    "$(pkg_content rb usr/libexec/chyx/rb-tool)" 'rb unharmed'

run_chy install ra
assert_rc 0 'ra reinstall'
run_chy remove ra rb
assert_rc 0 'remove both in one run'
assert_eq "$(grep '^- r[ab] ' "$OUT")" \
    "$(printf -- '- ra 1.0_1\n- rb 1.0_1')" \
    'completion lines exact and in argument order'
assert_absent "$CHY_ROOT/usr/libexec"
[ -d "$CHY_ROOT/usr" ] || fail 'top-level usr/ must survive full pruning'

# --- removing the only package in a root: prune empties usr/ completely
#     but must stop short of the top-level entry itself ---
proot="$TMPD/prune-root"
mkdir -p "$proot"
mkpkg "$proot" lone 1.0 usr/bin/deep/lone-tool
run_chy_root "$proot" install lone
assert_rc 0 'lone install'
run_chy_root "$proot" remove lone
assert_rc 0 'lone remove'
[ -d "$proot/usr" ] || fail 'top-level usr/ deleted while pruning the last package'
[ ! -h "$proot/usr" ] || fail 'top-level usr/ is a symlink'
assert_eq "$(ls -A "$proot/usr")" '' 'usr/ fully pruned inside, kept itself'

exit 0
