#!/bin/sh
# /overlay: overlay/<name>/, when it exists, IS the recipe for <name>,
# shadowing recipes/<name>/ per whole directory, never per file; the
# selected directory's build runs. An overlay pins its package:
# outdated and upgrade measure drift against the shadowing recipe, so
# default repo movement under an overlay stays invisible until the
# overlay goes away. The resolver reads overlay recipes for dependency
# names too. An invalid overlay fails the install (exit 1, before any
# fetching) and never falls back to the default repo.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# ovl_content NAME RELPATH - the content mkovl-built packages install;
# distinct from pkg_content so overlay and default repo builds are tellable apart.
ovl_content() {
    printf 'overlay:%s:%s' "$1" "$2"
}

# mkovl ROOT NAME VERSION-LINE [RELPATH...] - a complete script-only
# overlay recipe under overlay/<NAME>, same shapes as mkpkg's default
# repo recipes (an overlay recipe has to satisfy every rule on its
# own). The single source is cache-seeded behind an unreachable URL so
# any fetch attempt fails loudly; the seed basename differs from
# mkpkg's, and meta carries the overlay origin marker (never read).
mkovl() {
    ov_root=$1 ov_name=$2 ov_ver=$3
    shift 3
    ov_dir="$ov_root/overlay/$ov_name"
    rm -rf "$ov_dir"
    mkdir -p "$ov_dir" "$ov_root/cache"
    printf '%s\n' "$ov_ver" >"$ov_dir/version"
    printf 'overlay seed for %s\n' "$ov_name" >"$TMPD/ovseed-$ov_name.txt"
    cp "$TMPD/ovseed-$ov_name.txt" "$ov_root/cache/ovseed-$ov_name.txt"
    printf 'http://127.0.0.1:9/ovseed-%s.txt\n' "$ov_name" >"$ov_dir/sources"
    sha_of "$TMPD/ovseed-$ov_name.txt" >"$ov_dir/checksums"
    printf 'origin: overlay\n' >"$ov_dir/meta"
    printf 'set -eu\n' >"$ov_dir/build"
    for ov_p in "$@"; do
        ov_d=${ov_p%/*}
        if [ "$ov_d" != "$ov_p" ]; then
            printf "mkdir -p \"\$1\$CHY_ROOT/%s\"\n" "$ov_d" >>"$ov_dir/build"
        fi
        printf "printf '%%s\\\\n' '%s' >\"\$1\$CHY_ROOT/%s\"\n" \
            "$(ovl_content "$ov_name" "$ov_p")" "$ov_p" >>"$ov_dir/build"
    done
}

# --- 1. shadowing: while overlay/foo exists it IS the recipe for foo ---
mkpkg "$CHY_ROOT" foo 1.0 usr/bin/foo-tool
stamp_builds "$CHY_ROOT" foo "$TMPD"
mkovl "$CHY_ROOT" foo 2.0 usr/bin/foo-tool

run_chy install foo
assert_rc 0 'foo installs from the overlay'
assert_order_first 'foo'
file_has_line "$OUT" '+ foo 2.0_1'
assert_empty_file "$ERR" 'clean overlay install is silent on stderr'
assert_installed "$CHY_ROOT" foo 2.0 1
assert_link "$CHY_ROOT/store/foo" 'foo-2.0'
assert_absent "$CHY_ROOT/store/foo-1.0"
assert_eq "$(cat "$CHY_ROOT/usr/bin/foo-tool")" \
    "$(ovl_content foo usr/bin/foo-tool)" 'the artifact is the overlay build'
assert_absent "$TMPD/built-foo" # the shadowed default repo build never runs

# --- shadowing is per whole directory, never per file: the default repo
#     recipe's depends is invisible while the overlay (which has none)
#     exists ---
mkpkg "$CHY_ROOT" shadep 1.0 usr/bin/shadep-tool
mkpkg "$CHY_ROOT" whole 1.0 usr/bin/whole-tool
recipe_list "$CHY_ROOT" whole depends shadep
mkovl "$CHY_ROOT" whole 2.0 usr/bin/whole-tool

run_chy install whole
assert_rc 0 'whole installs from the overlay alone'
assert_order_first 'whole'
file_has_line "$OUT" '+ whole 2.0_1'
assert_installed "$CHY_ROOT" whole 2.0 1
assert_not_installed "$CHY_ROOT" shadep

# --- 2. pinning: drift is measured against the shadowing recipe ---
run_chy outdated
assert_rc 0 'outdated under an overlay exits 0'
assert_empty_file "$OUT" 'overlay 2.0 equals installed 2.0: default repo 1.0 is invisible'
assert_empty_file "$ERR"

printf '3.0\n' >"$CHY_ROOT/recipes/foo/version"
run_chy outdated
assert_rc 0 'outdated after the default repo moves under the overlay'
assert_empty_file "$OUT" 'default repo movement under an overlay stays invisible'
assert_empty_file "$ERR"

rm -rf "$CHY_ROOT/overlay/foo"
run_chy outdated
assert_rc 0 'outdated after the overlay goes away'
assert_eq "$(cat "$OUT")" 'foo 2.0 1 -> 3.0 1' \
    'default repo visible again for foo; whole stays pinned by its overlay'
assert_empty_file "$ERR"

run_chy upgrade
assert_rc 0 'upgrade converges foo to the default repo'
assert_order_first 'foo'
file_has_line "$OUT" '+ foo 3.0_1'
assert_eq "$(count_matches '^+ whole ' "$OUT")" 0 \
    'whole is pinned: upgrade never touches it'
assert_empty_file "$ERR"
assert_installed "$CHY_ROOT" foo 3.0 1
assert_installed "$CHY_ROOT" whole 2.0 1
[ -f "$TMPD/built-foo" ] || fail 'the default repo foo build must run now'
assert_eq "$(cat "$CHY_ROOT/usr/bin/foo-tool")" \
    "$(pkg_content foo usr/bin/foo-tool)" 'the artifact is the default repo build again'

run_chy outdated
assert_rc 0
assert_empty_file "$OUT" 'the root matches the default repo after upgrade'
assert_empty_file "$ERR"

# --- 3. overlay-only packages: resolve() reads the overlay for
#     dependency recipes, and an overlay-only name installs normally ---
mkovl "$CHY_ROOT" bar 1.0 usr/bin/bar-tool
mkovl "$CHY_ROOT" baz 1.0 usr/bin/baz-tool
printf 'bar\n' >"$CHY_ROOT/overlay/baz/depends" # depends lives in the overlay too

run_chy install baz
assert_rc 0 'baz resolves its overlay-only dependency'
assert_order_first 'bar baz'
assert_eq "$(installed_seq)" 'bar baz' 'builds run in the printed order'
assert_installed "$CHY_ROOT" bar 1.0 1
assert_installed "$CHY_ROOT" baz 1.0 1
assert_eq "$(cat "$CHY_ROOT/usr/bin/bar-tool")" \
    "$(ovl_content bar usr/bin/bar-tool)" 'bar is the overlay build'
assert_eq "$(cat "$CHY_ROOT/usr/bin/baz-tool")" \
    "$(ovl_content baz usr/bin/baz-tool)" 'baz is the overlay build'
assert_not_requested "$CHY_ROOT" bar
assert_requested "$CHY_ROOT" baz

run_chy install bar
assert_rc 0 'overlay-only bar installs by name'
assert_order_first 'bar'
file_has_line "$OUT" '+ bar 1.0_1'

run_chy outdated
assert_rc 0 'outdated with overlay-only packages installed'
assert_empty_file "$OUT" 'overlay-only packages are current'
assert_empty_file "$ERR" 'the overlay IS their recipe: no no-recipe warning'

# --- 4. an invalid overlay fails loud and never falls back to the
#     default repo. The overlay misses required checksums; its source is a
#     reachable file:// trap (a premature fetch would land in cache),
#     and the valid default repo recipe carries a build stamp (a fallback
#     build would leave it behind). ---
mkpkg "$CHY_ROOT" qux 1.0 usr/bin/qux-tool
stamp_builds "$CHY_ROOT" qux "$TMPD"
traps="$TMPD/traps"
mkdir -p "$traps"
printf 'trap payload qux\n' >"$traps/trap-qux.txt"
oq="$CHY_ROOT/overlay/qux"
mkdir -p "$oq"
printf '2.0\n' >"$oq/version"
printf 'file://%s/trap-qux.txt\n' "$traps" >"$oq/sources"
cat >"$oq/build" <<'EOF'
set -eu
mkdir -p "$1$CHY_ROOT/usr/bin"
printf 'ovqux\n' >"$1$CHY_ROOT/usr/bin/qux-tool"
EOF
# no checksums file: the overlay must be invalid on its own

run_chy install qux
assert_rc 1 'an invalid overlay fails the install'
file_matches "$ERR" '^chy: qux: error: '
file_has "$ERR" 'checksums' # the error wording names the culprit file
assert_eq "$(count_matches '^+ qux ' "$OUT")" 0 'no completion line'
assert_not_installed "$CHY_ROOT" qux
assert_no_store "$CHY_ROOT" qux 2.0
assert_absent "$CHY_ROOT/store/qux-1.0"
assert_absent "$CHY_ROOT/usr/bin/qux-tool"
assert_absent "$CHY_ROOT/cache/trap-qux.txt" # validation precedes fetching
assert_absent "$TMPD/built-qux" # the default repo recipe was never a fallback

exit 0
