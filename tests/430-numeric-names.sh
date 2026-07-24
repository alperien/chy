#!/bin/sh
# cycle reporting is pure byte order, even for names awk would happily
# read as numbers. 0 <-> 00 has to print `0 -> 00 -> 0` (numerically 0
# equals 00), and with neighbours 12 and 5 the printed path takes 12
# (byte-smallest, not numeric-smallest). Host awk and busybox awk must
# put out the same bytes: strnum comparisons used to differ between
# them, so the run repeats under a pure busybox PATH.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- mutual cycle between 0 and 00: distinct names, one exact line ---
mkpkg "$CHY_ROOT" 0 1.0 usr/bin/tool-0
mkpkg "$CHY_ROOT" 00 1.0 usr/bin/tool-00
recipe_list "$CHY_ROOT" 0 depends 00
recipe_list "$CHY_ROOT" 00 depends 0
run_chy install 0
assert_rc 1 'the 0/00 cycle fails resolution'
line_a=$(cat "$ERR")
assert_eq "$line_a" 'chy: install: error: dependency cycle: 0 -> 00 -> 0' \
    'exact cycle line, 0 and 00 kept distinct'
assert_empty_file "$OUT" 'cycle error prints no order line, no pipeline'
assert_not_installed "$CHY_ROOT" 0
assert_not_installed "$CHY_ROOT" 00

# --- neighbour tie-break: 12 beats 5 in byte order. The depends file
#     lists 5 first, so neither line order nor numeric order can fake a
#     pass. ---
nb="$TMPD/nb"
mkdir -p "$nb"
mkpkg "$nb" 0 1.0 usr/bin/nb-0
mkpkg "$nb" 12 1.0 usr/bin/nb-12
mkpkg "$nb" 5 1.0 usr/bin/nb-5
recipe_list "$nb" 0 depends 5 12
recipe_list "$nb" 12 depends 0
recipe_list "$nb" 5 depends 0
run_chy_root "$nb" install 0
assert_rc 1 'the 0/12/5 cycles fail resolution'
line_b=$(cat "$ERR")
assert_eq "$line_b" 'chy: install: error: dependency cycle: 0 -> 12 -> 0' \
    'byte-smallest neighbour 12, not numeric-smallest 5'
assert_empty_file "$OUT"
assert_not_installed "$nb" 0
assert_not_installed "$nb" 12
assert_not_installed "$nb" 5

# --- the same bytes under busybox sh/awk/sort ---
[ -x /tmp/busybox ] || { echo 'SKIP: /tmp/busybox unavailable'; exit 0; }
{ /tmp/busybox awk 'BEGIN { exit 0 }' && /tmp/busybox sort </dev/null &&
    /tmp/busybox sh -c ':'; } >/dev/null 2>&1 ||
    { echo 'SKIP: busybox applets unusable on this host'; exit 0; }
BB=$TMPD/bb
mkdir -p "$BB"
for bb_t in sh awk sort tr head rm mkdir rmdir wc uniq cat sed grep find \
    readlink ln cp mv touch env sha256sum cut ls; do
    ln -s /tmp/busybox "$BB/$bb_t"
done

# run_chy_bb ROOT VERB... - chy under busybox sh with only $BB in PATH.
run_chy_bb() {
    rb_root=$1
    shift
    RC=0
    CHY_ROOT="$rb_root" PATH="$BB" "$BB/sh" "$CHY" "$@" \
        >"$TMPD/run.out" 2>"$TMPD/run.err" || RC=$?
    OUT="$TMPD/run.out"
    ERR="$TMPD/run.err"
}

run_chy_bb "$CHY_ROOT" install 0
assert_rc 1 'busybox run of the 0/00 cycle'
assert_eq "$(cat "$ERR")" "$line_a" 'identical cycle line under busybox'
run_chy_bb "$nb" install 0
assert_rc 1 'busybox run of the 0/12/5 cycles'
assert_eq "$(cat "$ERR")" "$line_b" 'identical tie-break under busybox'

exit 0
