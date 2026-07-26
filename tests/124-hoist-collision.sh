#!/bin/sh
# hoisting moves the single top dir's whole contents (dotfiles too) up
# one level. Source content is arbitrary, so no tarball entry name may
# collide with chy's own hoist scratch. An entry named .chy-hoist (the
# old in-tree scratch name) once broke the install, .hoist guards the
# same class. The build checks the layout itself and exits nonzero on
# any deviation.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

command -v tar >/dev/null 2>&1 || { echo 'SKIP: tar unavailable'; exit 0; }
command -v gzip >/dev/null 2>&1 || { echo 'SKIP: gzip unavailable'; exit 0; }

t_init

mkdir -p "$TMPD/t-hc/hc-1.0/.chy-hoist"
printf 'c\n' >"$TMPD/t-hc/hc-1.0/configure"
printf 'survivor\n' >"$TMPD/t-hc/hc-1.0/.chy-hoist/keep.txt"
printf 'h\n' >"$TMPD/t-hc/hc-1.0/.hoist"
mktgz "$TMPD/hc-src.tar.gz" "$TMPD/t-hc" hc-1.0

mkdir -p "$CHY_ROOT/recipes/hc"
printf '1.0\n' >"$CHY_ROOT/recipes/hc/version"
add_source "$CHY_ROOT" hc "$TMPD/hc-src.tar.gz"
cat >"$CHY_ROOT/recipes/hc/build" <<'EOF'
set -eu
[ -f configure ] || { echo 'hc: configure not at build dir top' >&2; exit 9; }
[ -d .chy-hoist ] || { echo 'hc: .chy-hoist dir not hoisted' >&2; exit 9; }
[ "$(cat .chy-hoist/keep.txt)" = survivor ] || { echo 'hc: .chy-hoist content lost' >&2; exit 9; }
[ -f .hoist ] || { echo 'hc: .hoist entry not hoisted' >&2; exit 9; }
[ ! -e hc-1.0 ] || { echo 'hc: top dir left behind' >&2; exit 9; }
mkdir -p "$1$CHY_ROOT/usr/share/hc"
printf 'ok\n' >"$1$CHY_ROOT/usr/share/hc/marker"
EOF

run_chy install hc
assert_rc 0 'source entries named like hoist scratch survive hoisting'
file_has_line "$OUT" '+ hc 1.0_1'
assert_installed "$CHY_ROOT" hc 1.0 1
assert_link "$CHY_ROOT/usr/share/hc/marker" \
    '../../../store/hc/usr/share/hc/marker'

exit 0
