#!/bin/sh
# kiss-style staging: a build that installs prefix-relative under $1
# (mkdir -p "$1/usr/bin"; the whole $DEST tree is the image) normalizes
# and links like a chy-style recipe. A build staging into BOTH layouts
# is refused loudly, naming both roots.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- kiss-style: DESTDIR="$1/usr" shape ---
mkpkg "$CHY_ROOT" kissy 1.0
cat >"$CHY_ROOT/recipes/kissy/build" <<'EOF'
set -eu
# exactly what a kiss build script does: prefix-relative staging
mkdir -p "$1/usr/bin" "$1/usr/share/kissy" "$1/etc"
printf 'kissy-tool\n' >"$1/usr/bin/kissy-tool"
printf 'data\n' >"$1/usr/share/kissy/data.txt"
printf 'conf\n' >"$1/etc/kissy.conf"
ln -s kissy-tool "$1/usr/bin/kissy-alias"
EOF
run_chy install kissy
assert_rc 0 'kiss-style staging installs'
assert_installed "$CHY_ROOT" kissy 1.0 1
assert_link "$CHY_ROOT/usr/bin/kissy-tool" '../../store/kissy/usr/bin/kissy-tool'
assert_link "$CHY_ROOT/usr/share/kissy/data.txt" \
    '../../../store/kissy/usr/share/kissy/data.txt'
assert_link "$CHY_ROOT/etc/kissy.conf" '../store/kissy/etc/kissy.conf'
assert_eq "$(cat "$CHY_ROOT/usr/bin/kissy-tool")" 'kissy-tool'
assert_eq "$(cat "$CHY_ROOT/etc/kissy.conf")" 'conf'
# a relative link staged inside the tree links through the store too
assert_eq "$(cat "$CHY_ROOT/usr/bin/kissy-alias")" 'kissy-tool'

run_chy doctor
assert_rc 0 'doctor clean after a kiss-style install'
file_has_line "$OUT" 'doctor: clean'

# --- mixed: staging into both $1$CHY_ROOT and $1 directly is refused ---
mkpkg "$CHY_ROOT" mixed 1.0
cat >"$CHY_ROOT/recipes/mixed/build" <<'EOF'
set -eu
mkdir -p "$1$CHY_ROOT/usr/bin" "$1/usr/bin"
printf 'chy-side\n' >"$1$CHY_ROOT/usr/bin/mixed-chy"
printf 'kiss-side\n' >"$1/usr/bin/mixed-kiss"
EOF
snap0=$(snap "$CHY_ROOT")
run_chy install mixed
assert_rc 1 'a build staging both layouts is refused'
file_has "$ERR" 'ambiguous staging'
file_has "$ERR" "$CHY_ROOT/build/dest$CHY_ROOT"
file_has "$ERR" "$CHY_ROOT/build/dest"
file_has "$ERR" 'mixed-kiss'
assert_eq "$(snap "$CHY_ROOT")" "$snap0" 'root untouched by the refusal'
assert_not_installed "$CHY_ROOT" mixed

# --- empty $DEST$CHY_ROOT dir + kiss staging: still the kiss layout ---
# (make creates the DESTDIR root even when everything installs elsewhere)
mkpkg "$CHY_ROOT" emptyroot 1.0
cat >"$CHY_ROOT/recipes/emptyroot/build" <<'EOF'
set -eu
mkdir -p "$1$CHY_ROOT"          # the empty chy root: no evidence
mkdir -p "$1/usr/bin"
printf 'x\n' >"$1/usr/bin/emptyroot-tool"
EOF
run_chy install emptyroot
assert_rc 0 'an empty $DEST$CHY_ROOT does not force the chy layout'
assert_link "$CHY_ROOT/usr/bin/emptyroot-tool" \
    '../../store/emptyroot/usr/bin/emptyroot-tool'

# --- kiss layout: a path staged outside the image is still refused ---
mkpkg "$CHY_ROOT" escaper 1.0
cat >"$CHY_ROOT/recipes/escaper/build" <<'EOF'
set -eu
mkdir -p "$1/usr/bin"
printf 'x\n' >"$1/usr/bin/escaper-tool"
# a newline in a path: the fragment check must still catch it
printf 'y\n' >"$1/usr/bin/$(printf 'bad\nname')" 2>/dev/null || :
EOF
snap1=$(snap "$CHY_ROOT")
run_chy install escaper
assert_rc 1 'a newline path escapes the kiss image too'
file_has "$ERR" 'staged outside the prefix'
assert_eq "$(snap "$CHY_ROOT")" "$snap1" 'root untouched'

exit 0
