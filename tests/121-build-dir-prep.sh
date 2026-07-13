#!/bin/sh
# build dir prep: the first sources line, when it's a recognized tar
# archive with exactly one top-level entry (dotfiles count) that is a
# directory, gets hoisted one level, anything else doesn't. Every other
# source is extracted or copied without hoisting. The builds below
# check the layout themselves and exit nonzero on any deviation, a
# passing install is the whole assertion.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- single top-level directory (with a dotfile inside): hoisted ---
mkdir -p "$TMPD/t-hoist/hoist-1.0/sub"
printf 'c\n' >"$TMPD/t-hoist/hoist-1.0/configure"
printf 'd\n' >"$TMPD/t-hoist/hoist-1.0/.dotfile"
printf 'i\n' >"$TMPD/t-hoist/hoist-1.0/sub/inner.txt"
mktgz "$TMPD/hoist-src.tar.gz" "$TMPD/t-hoist" hoist-1.0

mkdir -p "$CHY_ROOT/recipes/hoist"
printf '1.0\n' >"$CHY_ROOT/recipes/hoist/version"
add_source "$CHY_ROOT" hoist "$TMPD/hoist-src.tar.gz"
cat >"$CHY_ROOT/recipes/hoist/build" <<'EOF'
set -eu
[ -f configure ] || { echo 'hoist: configure not at build dir top' >&2; exit 9; }
[ -f .dotfile ] || { echo 'hoist: dotfile was not hoisted along' >&2; exit 9; }
[ -f sub/inner.txt ] || { echo 'hoist: subdirectory not hoisted' >&2; exit 9; }
mkdir -p "$1$CHY_ROOT/usr/share/hoist"
printf 'ok\n' >"$1$CHY_ROOT/usr/share/hoist/marker"
EOF
run_chy install hoist
assert_rc 0 'single-top-dir tarball is hoisted so ./configure works'

# --- several top-level entries (.tgz): not hoisted ---
mkdir -p "$TMPD/t-multi/sub2"
printf 'r\n' >"$TMPD/t-multi/rootfile.txt"
printf 'i2\n' >"$TMPD/t-multi/sub2/inner2.txt"
mktgz "$TMPD/multi-src.tgz" "$TMPD/t-multi" rootfile.txt sub2

mkdir -p "$CHY_ROOT/recipes/multi"
printf '1.0\n' >"$CHY_ROOT/recipes/multi/version"
add_source "$CHY_ROOT" multi "$TMPD/multi-src.tgz"
cat >"$CHY_ROOT/recipes/multi/build" <<'EOF'
set -eu
[ -f rootfile.txt ] || { echo 'multi: rootfile.txt missing at top' >&2; exit 9; }
[ -f sub2/inner2.txt ] || { echo 'multi: sub2/inner2.txt missing' >&2; exit 9; }
[ ! -e inner2.txt ] || { echo 'multi: was wrongly hoisted' >&2; exit 9; }
mkdir -p "$1$CHY_ROOT/usr/share/multi"
printf 'ok\n' >"$1$CHY_ROOT/usr/share/multi/marker"
EOF
run_chy install multi
assert_rc 0 'multi-entry tarball is extracted in place, no hoist'

# --- exactly one top-level entry that is a FILE (.tar.xz): not hoisted ---
mkdir -p "$TMPD/t-onefile"
printf 'payload\n' >"$TMPD/t-onefile/onefile.txt"
mktarxz "$TMPD/onefile-src.tar.xz" "$TMPD/t-onefile" onefile.txt

mkdir -p "$CHY_ROOT/recipes/onefile"
printf '1.0\n' >"$CHY_ROOT/recipes/onefile/version"
add_source "$CHY_ROOT" onefile "$TMPD/onefile-src.tar.xz"
cat >"$CHY_ROOT/recipes/onefile/build" <<'EOF'
set -eu
[ -f onefile.txt ] || { echo 'onefile: extracted file missing' >&2; exit 9; }
[ "$(cat onefile.txt)" = 'payload' ] || { echo 'onefile: bad content' >&2; exit 9; }
mkdir -p "$1$CHY_ROOT/usr/share/onefile"
printf 'ok\n' >"$1$CHY_ROOT/usr/share/onefile/marker"
EOF
run_chy install onefile
assert_rc 0 'xz tarball recognized; single top-level file is not hoisted'

# --- a dir plus a top-level dotfile: two entries, so no hoist ---
mkdir -p "$TMPD/t-dot/almost"
printf 'c2\n' >"$TMPD/t-dot/almost/configure2"
printf 's\n' >"$TMPD/t-dot/.stray"
mktgz "$TMPD/dotstray-src.tar.gz" "$TMPD/t-dot" almost .stray

mkdir -p "$CHY_ROOT/recipes/dotstray"
printf '1.0\n' >"$CHY_ROOT/recipes/dotstray/version"
add_source "$CHY_ROOT" dotstray "$TMPD/dotstray-src.tar.gz"
cat >"$CHY_ROOT/recipes/dotstray/build" <<'EOF'
set -eu
[ -d almost ] || { echo 'dotstray: almost/ missing' >&2; exit 9; }
[ -f almost/configure2 ] || { echo 'dotstray: almost/configure2 missing' >&2; exit 9; }
[ -f .stray ] || { echo 'dotstray: top-level dotfile missing' >&2; exit 9; }
[ ! -e configure2 ] || { echo 'dotstray: hoisted despite dotfile sibling' >&2; exit 9; }
mkdir -p "$1$CHY_ROOT/usr/share/dotstray"
printf 'ok\n' >"$1$CHY_ROOT/usr/share/dotstray/marker"
EOF
run_chy install dotstray
assert_rc 0 'dotfiles count as top-level entries when deciding to hoist'

# --- second source is never hoisted, even as a single-top-dir archive ---
mkdir -p "$TMPD/t-aux/aux-1"
printf 'i3\n' >"$TMPD/t-aux/aux-1/inner3.txt"
mktgz "$TMPD/aux-src.tar.gz" "$TMPD/t-aux" aux-1

mkdir -p "$CHY_ROOT/recipes/twosrc"
printf '1.0\n' >"$CHY_ROOT/recipes/twosrc/version"
printf 'first seed\n' >"$TMPD/twosrc-first.txt"
add_source "$CHY_ROOT" twosrc "$TMPD/twosrc-first.txt"
add_source "$CHY_ROOT" twosrc "$TMPD/aux-src.tar.gz"
cat >"$CHY_ROOT/recipes/twosrc/build" <<'EOF'
set -eu
[ -f twosrc-first.txt ] || { echo 'twosrc: first source missing' >&2; exit 9; }
[ -f aux-1/inner3.txt ] || { echo 'twosrc: second source not extracted' >&2; exit 9; }
[ ! -e inner3.txt ] || { echo 'twosrc: second source was hoisted' >&2; exit 9; }
mkdir -p "$1$CHY_ROOT/usr/share/twosrc"
printf 'ok\n' >"$1$CHY_ROOT/usr/share/twosrc/marker"
EOF
run_chy install twosrc
assert_rc 0 'second sources are extracted without hoisting'

exit 0
