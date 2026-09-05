#!/bin/sh
# read-only verbs over recipes and the db: `search pattern` lists recipe
# names containing the substring with their recipe version/revision
# (overlay shadows repo per directory); `owns path...` exact-matches
# installed manifests, printing `name path`, erroring per unowned path
# with exit 1; `orphans` lists installed, unrequested, unreferenced
# packages list-style.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- search over recipes ---
mkpkg "$CHY_ROOT" libz 1.3.2 usr/bin/libz-tool
mkpkg "$CHY_ROOT" libpng '1.6.58 2' usr/bin/libpng-tool
mkpkg "$CHY_ROOT" zip 3.0 usr/bin/zip-tool
run_chy search lib
assert_rc 0 'search finds matching recipes'
assert_eq "$(cat "$OUT")" \
    "$(printf 'libpng 1.6.58 2\nlibz 1.3.2 1')" \
    'search prints name version rev, sorted, revision defaulted'

run_chy search z
assert_rc 0 'substring search matches anywhere'
assert_eq "$(cat "$OUT")" \
    "$(printf 'libz 1.3.2 1\nzip 3.0 1')" 'both z-names found'

run_chy search nomatch
assert_rc 0 'no matches is still exit 0'
assert_empty_file "$OUT" 'no matches prints nothing'

run_chy search
assert_rc 2 'search needs exactly one pattern'

# overlay shadows the repo dir wholesale
mkdir -p "$CHY_ROOT/overlay/libz"
printf '9.9 7\n' >"$CHY_ROOT/overlay/libz/version"
run_chy search libz
assert_rc 0
assert_eq "$(cat "$OUT")" 'libz 9.9 7' 'the overlay version wins, one line'

# --- owns ---
mkpkg "$CHY_ROOT" owner 1.0 usr/bin/owner-tool usr/share/owner/data
run_chy install owner
assert_rc 0 'owner installs'
run_chy owns usr/bin/owner-tool
assert_rc 0 'owns finds the owner'
assert_eq "$(cat "$OUT")" 'owner usr/bin/owner-tool'

run_chy owns usr/bin/owner-tool usr/share/owner/data
assert_rc 0 'two owned paths'
assert_eq "$(cat "$OUT")" \
    "$(printf 'owner usr/bin/owner-tool\nowner usr/share/owner/data')" \
    'one line per path, in argument order'

run_chy owns usr/bin/nobody
assert_rc 1 'an unowned path fails'
file_has_line "$ERR" 'chy: owns: error: no package owns usr/bin/nobody'
assert_empty_file "$OUT"

run_chy owns usr/bin/owner-tool usr/bin/nobody
assert_rc 1 'any unresolved path fails the run'
file_has_line "$OUT" 'owner usr/bin/owner-tool'
file_has "$ERR" 'no package owns usr/bin/nobody'

run_chy owns
assert_rc 2 'owns needs at least one path'

# --- orphans ---
mkpkg "$CHY_ROOT" base 1.0 usr/bin/base-tool
mkpkg "$CHY_ROOT" user 1.0 usr/bin/user-tool
recipe_list "$CHY_ROOT" user depends base
run_chy install user
assert_rc 0 'user pulls base as a dependency'
run_chy orphans
assert_rc 0 'orphans runs'
assert_empty_file "$OUT" 'a requested package and its required dep are not orphans'

# an installed package with no marker and no requirers is an orphan
mkpkg "$CHY_ROOT" stray 1.0 usr/bin/stray-tool
run_chy install stray
assert_rc 0 'stray installs'
rm -f "$CHY_ROOT/db/installed/stray/requested"
run_chy orphans
assert_eq "$(cat "$OUT")" 'stray 1.0 1' 'the unmarked unreferenced package is an orphan'

# a `a|b` db depends line keeps both alternatives off the list
mkpkg "$CHY_ROOT" alt_a 1.0 usr/bin/alt_a-tool
mkpkg "$CHY_ROOT" alt_b 1.0 usr/bin/alt_b-tool
mkpkg "$CHY_ROOT" alt_user 1.0 usr/bin/alt_user-tool
run_chy install alt_a alt_b alt_user
assert_rc 0 'alternatives install'
rm -f "$CHY_ROOT/db/installed/alt_a/requested" \
    "$CHY_ROOT/db/installed/alt_b/requested" \
    "$CHY_ROOT/db/installed/alt_user/requested"
printf 'alt_a|alt_b\n' >"$CHY_ROOT/db/installed/alt_user/depends"
run_chy orphans
assert_eq "$(cat "$OUT")" "$(printf 'alt_user 1.0 1\nstray 1.0 1')" \
    'the alternative guard keeps both providers off the orphan list'

exit 0
