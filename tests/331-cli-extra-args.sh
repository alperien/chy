#!/bin/sh
# version takes no arguments, anything after the verb, operand or flag,
# is a usage error: usage to stderr, exit 2, stdout silent. Extra
# arguments were once silently ignored. Also pins cmd_list's
# invalid-name arm: a malformed name is the pinned error line, exit 1,
# nothing listed.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- version alone still prints its one bare line ---
run_chy version
assert_rc 0 'bare version exits 0'
assert_empty_file "$ERR" 'version says nothing on stderr'
assert_eq "$(wc -l <"$OUT" | tr -d ' ')" '1' 'version prints exactly one line'
[ -s "$OUT" ] || fail 'version string is empty'

# --- version with an extra operand: usage to stderr, exit 2 ---
run_chy version extra
assert_rc 2 'version rejects operands'
[ -s "$ERR" ] || fail 'usage expected on stderr for version extra'
assert_empty_file "$OUT" 'no version string on a usage error'

# --- version with a flag: same ---
run_chy version --frobnicate
assert_rc 2 'version rejects flags'
[ -s "$ERR" ] || fail 'usage expected on stderr for version --frobnicate'
assert_empty_file "$OUT" 'no version string on a usage error'

# --- list with a malformed name: pinned error, exit 1, nothing listed ---
run_chy list 'bad!name'
assert_rc 1 'invalid name fails list'
file_has_line "$ERR" 'chy: bad!name: error: invalid package name'
assert_empty_file "$OUT" 'nothing listable was named'

exit 0
