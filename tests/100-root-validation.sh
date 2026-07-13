#!/bin/sh
# chy checks $CHY_ROOT at startup, exit 2 unless the path is absolute,
# has no whitespace and no . or .. components. Trailing slashes get
# stripped.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- relative path: refused, and never created ---
rel="chy-test-relroot.$$"
run_chy_root "$rel" list
assert_rc 2 'relative CHY_ROOT must be refused'
assert_absent "./$rel"

run_chy_root "$rel" install anything
assert_rc 2 'root is validated for install too'
assert_absent "./$rel"

# --- whitespace in the path: refused, and never created ---
run_chy_root "$TMPD/with space" list
assert_rc 2 'CHY_ROOT containing a space must be refused'
assert_absent "$TMPD/with space"

tabroot=$(printf '%s/tab\tdir' "$TMPD")
run_chy_root "$tabroot" list
assert_rc 2 'CHY_ROOT containing a tab must be refused'
assert_absent "$tabroot"

# --- . and .. components: refused, and never created ---
run_chy_root "$TMPD/./dotroot" list
assert_rc 2 'CHY_ROOT with a . component must be refused'
assert_absent "$TMPD/dotroot"

run_chy_root "$TMPD/up/../dotdotroot" list
assert_rc 2 'CHY_ROOT with a .. component must be refused'
assert_absent "$TMPD/dotdotroot"
assert_absent "$TMPD/up"

run_chy_root "." list
assert_rc 2 'CHY_ROOT of "." must be refused'

# --- trailing slashes are stripped: such a root works normally ---
mkpkg "$CHY_ROOT" ts 1.0 usr/bin/ts-tool
run_chy_root "$CHY_ROOT/" install ts
assert_rc 0 'a trailing slash is stripped, not refused'
assert_installed "$CHY_ROOT" ts 1.0 1
assert_link "$CHY_ROOT/usr/bin/ts-tool" '../../store/ts/usr/bin/ts-tool'
file_has_line "$CHY_ROOT/db/installed/ts/manifest" 'usr/bin/ts-tool'

run_chy_root "$CHY_ROOT//" list
assert_rc 0 'multiple trailing slashes are stripped'
assert_eq "$(cat "$OUT")" 'ts 1.0 1' 'list works through a slash-suffixed root'

exit 0
