#!/bin/sh
# db/provided and one-line recipe files are hand-edited text, so CRLF
# endings can't leak a CR into parsed names, versions, or kinds. A
# leaked CR once meant a provided name never matched, a CRLF version
# failed the grammar, and kind "binary" got rejected.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init
cr=$(printf '\r')

no_cr() { # file label - no carriage-return byte anywhere in the file
    if [ "$(tr -cd '\r' <"$1" | wc -c | tr -d ' ')" != 0 ]; then
        od -c "$1" >&2
        fail "$2: carriage return leaked through"
    fi
}

# --- (a) CRLF db/provided: clean listing, and the names satisfy installs ---
mkdir -p "$CHY_ROOT/db"
{
    printf '# host packages%s\n' "$cr"
    printf '%s\n' "$cr"
    printf 'hostpkg%s\n' "$cr"
    printf 'zed 1.0 extra tokens%s\n' "$cr"
} >"$CHY_ROOT/db/provided"

run_chy provided
assert_rc 0 'CRLF db/provided lists cleanly'
no_cr "$OUT" 'provided output'
assert_eq "$(cat "$OUT")" "$(printf 'hostpkg\nzed')" \
    'first tokens only, sorted, CR stripped'
assert_empty_file "$ERR"

run_chy install hostpkg
assert_rc 0 'a host-provided request is a warning, not an error'
file_has_line "$ERR" 'chy: hostpkg: warning: provided by the host'
assert_no_order
assert_empty_file "$OUT" 'everything provided: nothing on stdout'
assert_not_installed "$CHY_ROOT" hostpkg

# --- (b) CRLF version file: installs under the CR-free version ---
mkpkg "$CHY_ROOT" crver '2.1 3' usr/bin/crver-tool
printf '2.1 3%s\n' "$cr" >"$CHY_ROOT/recipes/crver/version"
run_chy install crver
assert_rc 0 'CRLF version file is accepted'
file_has_line "$OUT" 'chy: crver: installed 2.1 3'
assert_installed "$CHY_ROOT" crver 2.1 3
[ -d "$CHY_ROOT/store/crver-2.1" ] || fail 'store entry is not store/crver-2.1'
assert_link "$CHY_ROOT/store/crver" 'crver-2.1'

run_chy list crver
assert_rc 0 'list sees the CR-free version'
no_cr "$OUT" 'list output'
file_has_line "$OUT" 'crver 2.1 3'

# --- (c) CRLF kind file: "binary" plus CRLF is still kind binary ---
mkpkg "$CHY_ROOT" crkind 1.0 usr/bin/crkind-tool
printf 'binary%s\n' "$cr" >"$CHY_ROOT/recipes/crkind/kind"
run_chy install crkind
assert_rc 0 'kind "binary" with a CRLF ending is accepted'
file_has_line "$OUT" 'chy: crkind: installed 1.0 1'
assert_installed "$CHY_ROOT" crkind 1.0 1
assert_eq "$(count_matches 'unsupported kind' "$ERR")" 0 'kind was not rejected'

exit 0
