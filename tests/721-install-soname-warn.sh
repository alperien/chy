#!/bin/sh
# upgrade, ABI safety: a reinstall that drops a
# usr/lib soname prints `chy: <name>: warning: soname bump: <soname>` on
# stderr (pipeline step 7, old manifest vs new file list). Plain
# `install` emits the warning too but NEVER rebuilds dependents; only
# `upgrade` schedules a rebuild set. The soname set is filename-based:
# symlinks count, and the fully-versioned real file is dropped in favour
# of the soname link it backs.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# libfake v1 ships the classic chain: .so -> .so.1 -> .so.1.0.0
mkpkg "$CHY_ROOT" libfake 1.0
cat >"$CHY_ROOT/recipes/libfake/build" <<'EOF'
set -eu
mkdir -p "$1$CHY_ROOT/usr/lib"
printf 'libfake1\n' >"$1$CHY_ROOT/usr/lib/libfake.so.1.0.0"
ln -s libfake.so.1.0.0 "$1$CHY_ROOT/usr/lib/libfake.so.1"
ln -s libfake.so.1 "$1$CHY_ROOT/usr/lib/libfake.so"
EOF
mkpkg "$CHY_ROOT" app 1.0 usr/bin/app-tool
recipe_list "$CHY_ROOT" app depends libfake

run_chy install app
assert_rc 0 'app pulls libfake'
assert_order 'libfake app'
assert_empty_file "$ERR" 'a first install has no old manifest, no bump'
assert_requested "$CHY_ROOT" app

# v2 drops the .so.1 chain for .so.2; the unversioned .so link stays
mkpkg "$CHY_ROOT" libfake 2.0
cat >"$CHY_ROOT/recipes/libfake/build" <<'EOF'
set -eu
mkdir -p "$1$CHY_ROOT/usr/lib"
printf 'libfake2\n' >"$1$CHY_ROOT/usr/lib/libfake.so.2.0.0"
ln -s libfake.so.2.0.0 "$1$CHY_ROOT/usr/lib/libfake.so.2"
ln -s libfake.so.2 "$1$CHY_ROOT/usr/lib/libfake.so"
EOF
stamp_builds "$CHY_ROOT" app "$TMPD"

# --- plain install reinstall: the pinned bump warning, nothing else ---
run_chy install libfake
assert_rc 0 'the bump warning never affects exit status'
assert_eq "$(cat "$ERR")" 'chy: libfake: warning: soname bump: libfake.so.1' \
    'exactly the vanished soname link warns; .so.1.0.0 and .so do not'
assert_order 'libfake'
file_has_line "$OUT" '+ libfake 2.0_1'
assert_eq "$(installed_seq)" 'libfake' 'only libfake rebuilds'
if grep -q '^-> rebuild' "$OUT"; then
    dump_streams
    fail 'plain install must never announce a rebuild set'
fi
assert_installed "$CHY_ROOT" libfake 2.0 1
assert_link "$CHY_ROOT/store/libfake" 'libfake-2.0'
assert_link "$CHY_ROOT/usr/lib/libfake.so.2" \
    '../../store/libfake/usr/lib/libfake.so.2'
assert_absent "$CHY_ROOT/usr/lib/libfake.so.1"
assert_absent "$CHY_ROOT/usr/lib/libfake.so.1.0.0"

# --- the dependent is untouched: no rebuild, marker and payload intact ---
assert_absent "$TMPD/built-app"
assert_installed "$CHY_ROOT" app 1.0 1
assert_requested "$CHY_ROOT" app
assert_eq "$(cat "$CHY_ROOT/usr/bin/app-tool")" \
    "$(pkg_content app usr/bin/app-tool)" 'app rides through untouched'

exit 0
