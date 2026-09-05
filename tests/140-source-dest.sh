#!/bin/sh
# kiss source-line destinations: field 2 starting with / or ./ is a
# work-dir path to stage into (extract/copy there, never hoisted); any
# other field 2 stays a chy mirror URL. A dest with a .. component is
# refused. Hermetic: sources are pre-seeded cache entries.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

command -v tar >/dev/null 2>&1 || { echo 'SKIP: tar unavailable'; exit 0; }

# --- archive with an absolute dest: extracted into $WORK/dest ---
mkdir -p "$TMPD/payload/sub"
printf 'inner\n' >"$TMPD/payload/sub/inner.txt"
(cd "$TMPD" && tar cf pay.tar payload)

r="$CHY_ROOT/recipes/dstarc"
mkdir -p "$r" "$CHY_ROOT/cache"
printf '1.0\n' >"$r/version"
printf 'http://127.0.0.1:9/pay.tar /extract-here\n' >"$r/sources"
sha_of "$TMPD/pay.tar" >"$r/checksums"
cp "$TMPD/pay.tar" "$CHY_ROOT/cache/pay.tar"
cat >"$r/build" <<'EOF'
set -eu
# the archive must be under the named subdir, not the work root
[ -f extract-here/payload/sub/inner.txt ] ||
    { echo 'dstarc: archive not staged under the dest' >&2; exit 8; }
[ -f payload ] && { echo 'dstarc: also hoisted to root' >&2; exit 8; }
mkdir -p "$1$CHY_ROOT/usr/bin"
printf 'x\n' >"$1$CHY_ROOT/usr/bin/dstarc-tool"
EOF
run_chy install dstarc
assert_rc 0 'archive staged under an absolute dest'
assert_installed "$CHY_ROOT" dstarc 1.0 1

# --- plain file with a ./ dest: copied there ---
printf 'conf data\n' >"$TMPD/my.conf"
r="$CHY_ROOT/recipes/dstfile"
mkdir -p "$r"
printf '1.0\n' >"$r/version"
printf 'http://127.0.0.1:9/my.conf ./vendor/conf\n' >"$r/sources"
sha_of "$TMPD/my.conf" >"$r/checksums"
cp "$TMPD/my.conf" "$CHY_ROOT/cache/my.conf"
cat >"$r/build" <<'EOF'
set -eu
[ -f vendor/conf/my.conf ] ||
    { echo 'dstfile: file not staged under the ./ dest' >&2; exit 8; }
[ -f my.conf ] && { echo 'dstfile: also copied to root' >&2; exit 8; }
mkdir -p "$1$CHY_ROOT/usr/bin" "$1$CHY_ROOT/etc"
install -m 644 vendor/conf/my.conf "$1$CHY_ROOT/etc/my.conf"
printf 'x\n' >"$1$CHY_ROOT/usr/bin/dstfile-tool"
EOF
run_chy install dstfile
assert_rc 0 'plain file staged under a ./ dest'
assert_eq "$(cat "$CHY_ROOT/etc/my.conf")" 'conf data'

# --- dest source first: no hoisting happens at all afterwards ---
mkdir -p "$TMPD/hoistme"
printf 'deep\n' >"$TMPD/hoistme/only.txt"
(cd "$TMPD" && tar cf hoist.tar hoistme)
r="$CHY_ROOT/recipes/nohoist"
mkdir -p "$r"
printf '1.0\n' >"$r/version"
printf 'http://127.0.0.1:9/my.conf ./side\nhttp://127.0.0.1:9/hoist.tar\n' \
    >"$r/sources"
{ sha_of "$TMPD/my.conf"; sha_of "$TMPD/hoist.tar"; } >"$r/checksums"
cp "$TMPD/hoist.tar" "$CHY_ROOT/cache/hoist.tar"
# hoist.tar extracted second: the dest source consumed the first slot,
# and only the first source ever hoists, so hoistme stays put
cat >"$r/build" <<'EOF'
[ -d hoistme ] || { echo 'nohoist: hoisting ran anyway' >&2; exit 8; }
[ -f side/my.conf ] || { echo 'nohoist: dest source missing' >&2; exit 8; }
mkdir -p "$1$CHY_ROOT/usr/bin"
printf 'x\n' >"$1$CHY_ROOT/usr/bin/nohoist-tool"
EOF
run_chy install nohoist
assert_rc 0 'a dest first source disables hoisting'

# --- a second field that is NOT dest-shaped stays a mirror ---
mkdir -p "$TMPD/mirror"
printf 'conf data\n' >"$TMPD/mirror/my-mirror.conf"
r="$CHY_ROOT/recipes/mirrordest"
mkdir -p "$r"
printf '1.0\n' >"$r/version"
printf 'http://127.0.0.1:9/my-mirror.conf file://%s/mirror/my-mirror.conf\n' \
    "$TMPD" >"$r/sources"
sha_of "$TMPD/mirror/my-mirror.conf" >"$r/checksums"
cat >"$r/build" <<'EOF'
set -eu
[ -f my-mirror.conf ] || { echo 'mirrordest: mirror fetch broken' >&2; exit 8; }
mkdir -p "$1$CHY_ROOT/usr/bin"
printf 'x\n' >"$1$CHY_ROOT/usr/bin/mirrordest-tool"
EOF
run_chy install mirrordest
assert_rc 0 'a URL second field still mirrors (unchanged behavior)'

# --- traversal dest refused ---
r="$CHY_ROOT/recipes/escdest"
mkdir -p "$r"
printf '1.0\n' >"$r/version"
printf 'http://127.0.0.1:9/my.conf /ok/../escape\n' >"$r/sources"
sha_of "$TMPD/my.conf" >"$r/checksums"
cp "$TMPD/my.conf" "$CHY_ROOT/cache/my.conf"
cat >"$r/build" <<'EOF'
set -eu
mkdir -p "$1$CHY_ROOT/usr/bin"
printf 'x\n' >"$1$CHY_ROOT/usr/bin/escdest-tool"
EOF
snap0=$(snap "$CHY_ROOT")
run_chy install escdest
assert_rc 1 'a ..-traversing dest is refused'
file_has "$ERR" 'unsafe source destination: /ok/../escape'
assert_eq "$(snap "$CHY_ROOT")" "$snap0" 'root untouched'

exit 0
