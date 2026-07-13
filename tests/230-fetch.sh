#!/bin/sh
# a cached file with a matching sha256 is used with no download at all.
# A corrupt cached file gets deleted and the line's URLs walked in
# order (mismatching downloads deleted, next URL tried), an exhausted
# list fails showing expected and actual digests. Hermetic: the only
# reachable URLs are file:// paths inside the test's own temp dir.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- verified cache hit: unreachable URL + good cache = success ---
mkpkg "$CHY_ROOT" hit 1.0 usr/bin/hit-tool
pre=$(sha_of "$CHY_ROOT/cache/seed-hit.txt")
run_chy install hit
assert_rc 0 'verified cache hit needs no network'
assert_installed "$CHY_ROOT" hit 1.0 1
assert_eq "$(sha_of "$CHY_ROOT/cache/seed-hit.txt")" "$pre" 'cache file kept'

# --- corrupt cache: deleted, URL list walked in order, mirror rescues ---
# The mirror URL's basename differs on purpose: the cache is keyed by the
# basename of the line's FIRST URL.
mkdir -p "$TMPD/mirror"
printf 'good mirror payload\n' >"$TMPD/mirror/m1-alt.txt"
good=$(sha_of "$TMPD/mirror/m1-alt.txt")

r="$CHY_ROOT/recipes/m1"
mkdir -p "$r"
printf '1.0\n' >"$r/version"
printf 'http://127.0.0.1:9/m1-src.txt file://%s/mirror/m1-alt.txt\n' \
    "$TMPD" >"$r/sources"
printf '%s\n' "$good" >"$r/checksums"
cat >"$r/build" <<'EOF'
set -eu
[ -f m1-src.txt ] || { echo 'm1: source missing under line filename' >&2; exit 9; }
[ "$(cat m1-src.txt)" = 'good mirror payload' ] || { echo 'm1: bad content' >&2; exit 9; }
mkdir -p "$1$CHY_ROOT/usr/bin"
printf 'm\n' >"$1$CHY_ROOT/usr/bin/m1-tool"
EOF
mkdir -p "$CHY_ROOT/cache"
printf 'corrupt payload\n' >"$CHY_ROOT/cache/m1-src.txt"

run_chy install m1
assert_rc 0 'corrupt cache degrades to the mirror'
assert_installed "$CHY_ROOT" m1 1.0 1
assert_eq "$(sha_of "$CHY_ROOT/cache/m1-src.txt")" "$good" \
    'cache refreshed under the first-URL basename'
assert_absent "$CHY_ROOT/cache/m1-alt.txt"

# --- exhausted URL list: fails showing expected AND actual digests ---
printf 'wanted payload\n' >"$TMPD/wanted.txt"
want=$(sha_of "$TMPD/wanted.txt")
printf 'wrong payload\n' >"$TMPD/mirror/m2-src.txt"
wrong=$(sha_of "$TMPD/mirror/m2-src.txt")

r="$CHY_ROOT/recipes/m2"
mkdir -p "$r"
printf '1.0\n' >"$r/version"
printf 'http://127.0.0.1:9/m2-src.txt file://%s/mirror/m2-src.txt\n' \
    "$TMPD" >"$r/sources"
printf '%s\n' "$want" >"$r/checksums"
cat >"$r/build" <<'EOF'
set -eu
mkdir -p "$1$CHY_ROOT/usr/bin"
printf 'never\n' >"$1$CHY_ROOT/usr/bin/m2-tool"
EOF
printf 'corrupt two\n' >"$CHY_ROOT/cache/m2-src.txt"

snap0=$(snap "$CHY_ROOT")
run_chy install m2
assert_rc 1 'exhausted source list fails the install'
file_has "$ERR" "$want"
file_has "$ERR" "$wrong"
assert_absent "$CHY_ROOT/cache/m2-src.txt"
assert_eq "$(snap "$CHY_ROOT")" "$snap0" 'root untouched by fetch failure'
assert_not_installed "$CHY_ROOT" m2
assert_no_store "$CHY_ROOT" m2 1.0
assert_absent "$CHY_ROOT/usr/bin/m2-tool"

exit 0
