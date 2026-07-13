#!/bin/sh
# farm dirs are real directories, every store file and symlink becomes
# a relative farm symlink through the store/<name> alias, and a store
# directory with no files in it isn't farmed.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

mkpkg "$CHY_ROOT" linky 2.0
cat >"$CHY_ROOT/recipes/linky/build" <<'EOF'
set -eu
mkdir -p "$1$CHY_ROOT/usr/bin" "$1$CHY_ROOT/usr/lib" \
    "$1$CHY_ROOT/usr/share/doc/linky" "$1$CHY_ROOT/usr/share/blank"
printf 'tool\n' >"$1$CHY_ROOT/usr/bin/tool"
printf 'readme\n' >"$1$CHY_ROOT/usr/share/doc/linky/README"
printf 'solib\n' >"$1$CHY_ROOT/usr/lib/liblinky.so.2.0"
ln -s liblinky.so.2.0 "$1$CHY_ROOT/usr/lib/liblinky.so"
EOF

run_chy install linky
assert_rc 0 'linky install'

# the stable alias sits beside the entry, relative
assert_link "$CHY_ROOT/store/linky" 'linky-2.0'

# farm links are relative and point through the alias, exact shape
assert_link "$CHY_ROOT/usr/bin/tool" '../../store/linky/usr/bin/tool'
assert_link "$CHY_ROOT/usr/share/doc/linky/README" \
    '../../../../store/linky/usr/share/doc/linky/README'
assert_link "$CHY_ROOT/usr/lib/liblinky.so.2.0" \
    '../../store/linky/usr/lib/liblinky.so.2.0'
# a store symlink gets its own farm symlink at the same relative path
assert_link "$CHY_ROOT/usr/lib/liblinky.so" '../../store/linky/usr/lib/liblinky.so'

# links resolve end to end (farm -> alias -> entry -> file)
assert_eq "$(cat "$CHY_ROOT/usr/bin/tool")" 'tool' 'farm file resolves'
assert_eq "$(cat "$CHY_ROOT/usr/lib/liblinky.so")" 'solib' \
    'farm link over store symlink resolves'

# farm directories are real directories, never symlinks
for d in usr usr/bin usr/lib usr/share usr/share/doc usr/share/doc/linky; do
    [ -d "$CHY_ROOT/$d" ] || fail "farm dir missing: $d"
    [ ! -h "$CHY_ROOT/$d" ] || fail "farm dir is a symlink: $d"
done

# an empty store directory stays store-only
assert_absent "$CHY_ROOT/usr/share/blank"

# the manifest records the store symlink's farm path too (files and
# symlinks, not directories)
m="$CHY_ROOT/db/installed/linky/manifest"
file_has_line "$m" 'usr/lib/liblinky.so'
file_has_line "$m" 'usr/lib/liblinky.so.2.0'
file_has_line "$m" 'usr/bin/tool'
file_has_line "$m" 'usr/share/doc/linky/README'

exit 0
