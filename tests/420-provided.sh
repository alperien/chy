#!/bin/sh
# provided: print the names from db/provided, sorted (byte order),
# de-duplicated, one per line, exit 0. The file is parsed by
# significant-line rule: blanks and #-lines ignored, the first
# whitespace-delimited token of a significant line is the name, the rest
# of the line is ignored. Absent or empty file means empty output, exit 0.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- absent file: empty output, exit 0 ---
run_chy provided
assert_rc 0 'absent db/provided is fine'
assert_empty_file "$OUT" 'no file, no output'
assert_empty_file "$ERR"

# --- empty file: same ---
mkdir -p "$CHY_ROOT/db"
: >"$CHY_ROOT/db/provided"
run_chy provided
assert_rc 0 'empty db/provided is fine'
assert_empty_file "$OUT"
assert_empty_file "$ERR"

# --- comments and blanks only: still empty ---
printf '# nothing but commentary\n\n# and more\n' >"$CHY_ROOT/db/provided"
run_chy provided
assert_rc 0
assert_empty_file "$OUT" 'comment-only file yields no names'

# --- the works: comments, blanks, duplicates, extra tokens, byte order ---
{
    printf '# host packages\n'
    printf 'zeta 5.9 some extra tokens\n'
    printf '\n'
    printf 'p.q trailing ignored\n'
    printf 'alpha\n'
    printf 'zeta\n'
    printf 'p-q\n'
    printf 'alpha\n'
} >"$CHY_ROOT/db/provided"
run_chy provided
assert_rc 0 'provided lists cleanly'
assert_eq "$(cat "$OUT")" "$(printf 'alpha\np-q\np.q\nzeta')" \
    'sorted in byte order, de-duplicated, first token only'
assert_empty_file "$ERR"

exit 0
