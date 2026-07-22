#!/bin/sh
# remove -r: cascade over db-recorded depends. Unrequested
# packages in the named packages' closure go, `requested`-marked members
# survive, and members kept alive only by each other (mutual orphans)
# still go. An installed outsider requiring a NAMED package refuses the
# whole run. Removal order is the exact reverse of deterministic
# order. Packages outside the set are untouched.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- simple chain: par -> mid -> leaf, orphans removed, reverse order,
#     an unrelated bystander untouched ---
mkpkg "$CHY_ROOT" bystander 1.0 usr/bin/bystander-tool
run_chy install bystander
assert_rc 0 'bystander installs'
mkpkg "$CHY_ROOT" leaf 1.0 usr/bin/leaf-tool
mkpkg "$CHY_ROOT" mid 1.0 usr/bin/mid-tool
mkpkg "$CHY_ROOT" par 1.0 usr/bin/par-tool
recipe_list "$CHY_ROOT" mid depends leaf
recipe_list "$CHY_ROOT" par depends mid
run_chy install par
assert_rc 0 'par pulls the chain'
assert_order 'leaf mid par'

run_chy remove -r par
assert_rc 0 'cascade removes the orphaned chain'
assert_eq "$(removed_seq)" 'par mid leaf' \
    'removal order is the reverse of the deterministic order'
assert_not_installed "$CHY_ROOT" par
assert_not_installed "$CHY_ROOT" mid
assert_not_installed "$CHY_ROOT" leaf
assert_installed "$CHY_ROOT" bystander 1.0 1
assert_eq "$(cat "$CHY_ROOT/usr/bin/bystander-tool")" \
    "$(pkg_content bystander usr/bin/bystander-tool)" 'bystander untouched'

# --- a requested-marked member of the closure survives (and so does what
#     it still needs) ---
rb="$TMPD/rb"
mkdir -p "$rb"
mkpkg "$rb" leafq 1.0 usr/bin/leafq-tool
mkpkg "$rb" midq 1.0 usr/bin/midq-tool
mkpkg "$rb" parq 1.0 usr/bin/parq-tool
recipe_list "$rb" midq depends leafq
recipe_list "$rb" parq depends midq
run_chy_root "$rb" install midq
assert_rc 0 'midq requested by name first'
run_chy_root "$rb" install parq
assert_rc 0 'parq rides on the satisfied midq'

run_chy_root "$rb" remove -r parq
assert_rc 0 'cascade respects the requested marker'
assert_eq "$(removed_seq)" 'parq' 'only the named package goes'
assert_not_installed "$rb" parq
assert_installed "$rb" midq 1.0 1
assert_installed "$rb" leafq 1.0 1

# --- mutual orphans under a named parent: both removed. The mutual db
#     edge is the --no-deps debt state, and the cascade reads only the
#     db, so the fixture writes that db state directly: ob's recorded
#     depends gains oa alongside the chy-recorded oa -> ob. ---
rc="$TMPD/rc"
mkdir -p "$rc"
mkpkg "$rc" ob 1.0 usr/bin/ob-tool
mkpkg "$rc" oa 1.0 usr/bin/oa-tool
mkpkg "$rc" pm 1.0 usr/bin/pm-tool
recipe_list "$rc" oa depends ob
recipe_list "$rc" pm depends oa
run_chy_root "$rc" install pm
assert_rc 0 'pm pulls oa and ob'
assert_order 'ob oa pm'
printf 'oa\n' >"$rc/db/installed/ob/depends"

run_chy_root "$rc" remove -r pm
assert_rc 0 'mutual orphans that only reference each other are removed'
assert_eq "$(removed_seq)" 'pm ob oa' \
    'cycle broken at the smallest member, order still reverse-deterministic'
assert_not_installed "$rc" pm
assert_not_installed "$rc" oa
assert_not_installed "$rc" ob

# --- an installed outsider requiring a NAMED package: refusal, nothing
#     removed at all ---
rd="$TMPD/rd"
mkdir -p "$rd"
mkpkg "$rd" libn 1.0 usr/bin/libn-tool
mkpkg "$rd" appn 1.0 usr/bin/appn-tool
mkpkg "$rd" outs 1.0 usr/bin/outs-tool
recipe_list "$rd" appn depends libn
recipe_list "$rd" outs depends appn
run_chy_root "$rd" install appn
assert_rc 0 'appn pulls libn'
run_chy_root "$rd" install outs
assert_rc 0 'outs rides on appn'
snap0=$(snap "$rd")

run_chy_root "$rd" remove -r appn
assert_rc 1 'a named package required from outside refuses the cascade'
assert_eq "$(cat "$ERR")" 'chy: appn: error: required by: outs' \
    'exact pinned required-by line'
assert_empty_file "$OUT" 'refusal removes nothing, says nothing on stdout'
assert_eq "$(snap "$rd")" "$snap0" 'the root is exactly as it was'

# --- diamond closure: reverse deterministic order across siblings ---
re="$TMPD/re"
mkdir -p "$re"
mkpkg "$re" base 1.0 usr/bin/base-tool
mkpkg "$re" la 1.0 usr/bin/la-tool
mkpkg "$re" lb 1.0 usr/bin/lb-tool
mkpkg "$re" topd 1.0 usr/bin/topd-tool
recipe_list "$re" la depends base
recipe_list "$re" lb depends base
recipe_list "$re" topd depends la lb
run_chy_root "$re" install topd
assert_rc 0 'diamond installs'
assert_order 'base la lb topd'

run_chy_root "$re" remove -r topd
assert_rc 0 'diamond cascade'
assert_eq "$(removed_seq)" 'topd lb la base' \
    'exact reverse of the deterministic order'
assert_not_installed "$re" topd
assert_not_installed "$re" la
assert_not_installed "$re" lb
assert_not_installed "$re" base

exit 0
