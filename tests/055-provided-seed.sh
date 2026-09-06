#!/bin/sh
# db/provided auto-seeds from the repo's provided.suggested on mutating
# verbs only: install unions the suggested names (column 1) beside the
# recipes/ symlink, user names survive, steady state never rewrites the
# file, and read verbs create nothing.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- install seeds from a symlinked repo; provided names resolve ---
repodir="$TMPD/repodir"
mkdir -p "$repodir/recipes"
rmdir "$CHY_ROOT/recipes" 2>/dev/null || rm -rf "$CHY_ROOT/recipes"
ln -s "$repodir/recipes" "$CHY_ROOT/recipes"
printf 'hostlib hostlib,hostlib-devel\nghost\n# a comment\n\n' \
    >"$repodir/provided.suggested"
mkpkg "$CHY_ROOT" needhost 1.0 usr/bin/needhost-tool
recipe_list "$CHY_ROOT" needhost depends 'hostlib'
run_chy install needhost
assert_rc 0 'a dep the repo suggests is provided, not built'
assert_installed "$CHY_ROOT" needhost 1.0 1
assert_not_installed "$CHY_ROOT" hostlib
file_has_line "$CHY_ROOT/db/provided" 'hostlib'
file_has_line "$CHY_ROOT/db/provided" 'ghost'
run_chy install hostlib
assert_rc 0 'a suggested name requested directly is skipped'
file_has "$ERR" 'provided by the host'

# --- the union keeps user-added names ---
printf 'myname\n' >>"$CHY_ROOT/db/provided"
mkpkg "$CHY_ROOT" need2 1.0 usr/bin/need2-tool
run_chy install need2
assert_rc 0 'install with a seeded provided file'
assert_eq "$(LC_ALL=C sort "$CHY_ROOT/db/provided" | tr '\n' ' ')" \
    'ghost hostlib myname ' 'the union keeps myname'

# --- steady state: a rerun rewrites nothing ---
mt1=$(stat -c %y "$CHY_ROOT/db/provided")
run_chy install need2
assert_rc 0 'a second install succeeds'
assert_eq "$(stat -c %y "$CHY_ROOT/db/provided")" "$mt1" \
    'the unchanged seed file is not rewritten'

# --- no provided.suggested: nothing is seeded ---
t_init
mkpkg "$CHY_ROOT" plain 1.0 usr/bin/plain-tool
run_chy install plain
assert_rc 0 'install without a suggested file'
assert_absent "$CHY_ROOT/db/provided"

# --- read verbs never create the file ---
t_init
run_chy list
assert_rc 0 'list on an empty root'
assert_absent "$CHY_ROOT/db/provided"
run_chy provided
assert_rc 0 'provided on an empty root'
assert_absent "$CHY_ROOT/db/provided"

exit 0
