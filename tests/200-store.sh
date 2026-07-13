#!/bin/sh
# normalization - store entries are $CHY_ROOT-relative (top level
# usr/, never a deep mirror); staging outside $1$CHY_ROOT, staging nothing,
# and DESTDIR-baked symlink targets are errors that leave the root as it
# was. Name/version collisions on store paths fail rather than guess.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- normalized shape: top level of the store entry is usr/, no mirror ---
mkpkg "$CHY_ROOT" norm 1.0 usr/bin/norm-tool usr/share/norm/data
run_chy install norm
assert_rc 0 'norm install'
assert_eq "$(ls -A "$CHY_ROOT/store/norm-1.0")" 'usr' \
    'store entry top level is exactly usr/'
[ -f "$CHY_ROOT/store/norm-1.0/usr/bin/norm-tool" ] \
    || fail 'store entry misses usr/bin/norm-tool'
assert_eq "$(cat "$CHY_ROOT/store/norm-1.0/usr/bin/norm-tool")" \
    "$(pkg_content norm usr/bin/norm-tool)" 'store file content intact'
# no deep mirror of the absolute root path inside the entry
rootfirst=${CHY_ROOT#/}
rootfirst=${rootfirst%%/*}
assert_absent "$CHY_ROOT/store/norm-1.0/$rootfirst"

# --- files or symlinks staged outside $1$CHY_ROOT: error, listed ---
mkpkg "$CHY_ROOT" rogue 1.0
cat >"$CHY_ROOT/recipes/rogue/build" <<'EOF'
set -eu
mkdir -p "$1$CHY_ROOT/usr/bin" "$1/rogue-dir"
printf 'ok\n' >"$1$CHY_ROOT/usr/bin/rogue-tool"
printf 'r\n' >"$1/rogue-dir/rogue-file"
ln -s /nowhere "$1/rogue-link"
EOF
snap0=$(snap "$CHY_ROOT")
run_chy install rogue
assert_rc 1 'staging outside the DESTDIR root image fails'
file_has "$ERR" 'rogue-file'
file_has "$ERR" 'rogue-link'
assert_eq "$(snap "$CHY_ROOT")" "$snap0" 'root untouched by rogue staging'
assert_not_installed "$CHY_ROOT" rogue
assert_absent "$CHY_ROOT/usr/bin/rogue-tool"

# --- nothing staged at all: "build installed nothing" ---
mkpkg "$CHY_ROOT" nothing 1.0
snap0=$(snap "$CHY_ROOT")
run_chy install nothing
assert_rc 1 'a build that stages nothing fails'
file_has "$ERR" 'installed nothing'
assert_eq "$(snap "$CHY_ROOT")" "$snap0" 'root untouched'
assert_not_installed "$CHY_ROOT" nothing

# --- staged symlink whose target begins with $1: error, listed ---
mkpkg "$CHY_ROOT" baked 1.0
cat >"$CHY_ROOT/recipes/baked/build" <<'EOF'
set -eu
mkdir -p "$1$CHY_ROOT/usr/bin"
printf 't\n' >"$1$CHY_ROOT/usr/bin/baked-tool"
ln -s "$1$CHY_ROOT/usr/bin/baked-tool" "$1$CHY_ROOT/usr/bin/baked-alias"
EOF
snap0=$(snap "$CHY_ROOT")
run_chy install baked
assert_rc 1 'DESTDIR-baked symlink target fails the install'
file_has "$ERR" 'baked-alias'
assert_eq "$(snap "$CHY_ROOT")" "$snap0" 'root untouched by baked link'
assert_not_installed "$CHY_ROOT" baked
assert_absent "$CHY_ROOT/usr/bin/baked-tool"

# --- store path collisions fail rather than guess ---
# package literally named "clash-1.0": its alias occupies store/clash-1.0
mkpkg "$CHY_ROOT" clash-1.0 1.0 usr/bin/c-hyphen
run_chy install clash-1.0
assert_rc 0 'hyphenated package name installs'
assert_link "$CHY_ROOT/store/clash-1.0" 'clash-1.0-1.0'

# now package "clash" version 1.0 needs store/clash-1.0 as a directory
mkpkg "$CHY_ROOT" clash 1.0 usr/bin/c-plain
run_chy install clash
assert_rc 1 'store entry path occupied by an alias symlink must fail'
assert_not_installed "$CHY_ROOT" clash
assert_absent "$CHY_ROOT/usr/bin/c-plain"
assert_link "$CHY_ROOT/store/clash-1.0" 'clash-1.0-1.0'
run_chy list clash-1.0
assert_rc 0
assert_eq "$(cat "$OUT")" 'clash-1.0 1.0 1' 'existing package undamaged'

# reverse shape, in a fresh root: alias path occupied by a real directory
root2="$TMPD/root2"
mkdir -p "$root2"
mkpkg "$root2" clash 1.0 usr/bin/c-plain
run_chy_root "$root2" install clash
assert_rc 0 'plain clash installs into the fresh root'
mkpkg "$root2" clash-1.0 1.0 usr/bin/c-hyphen
run_chy_root "$root2" install clash-1.0
assert_rc 1 'alias path occupied by a real store directory must fail'
assert_not_installed "$root2" clash-1.0
assert_absent "$root2/usr/bin/c-hyphen"
[ -d "$root2/store/clash-1.0" ] || fail 'victim store entry vanished'
[ ! -h "$root2/store/clash-1.0" ] || fail 'victim store entry became a symlink'
assert_eq "$(cat "$root2/usr/bin/c-plain")" \
    "$(pkg_content clash usr/bin/c-plain)" 'victim package still resolves'

exit 0
