#!/bin/sh
# db/installed/<name>/ holds version ("<version> <revision>",
# always two tokens), a sorted $CHY_ROOT-relative manifest of the farm
# paths created (files and symlinks, not directories), and a verbatim copy
# of the recipe's depends when present.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# --- explicit revision; manifest sorted regardless of creation order ---
mkpkg "$CHY_ROOT" dbp '4.2 7' usr/bin/zeta usr/bin/alpha usr/share/dbp/x
run_chy install dbp
assert_rc 0 'dbp install'

v="$CHY_ROOT/db/installed/dbp/version"
assert_eq "$(cat "$v")" '4.2 7' 'version file holds both tokens'
assert_eq "$(wc -l <"$v" | tr -d ' ')" '1' 'version file is one line'

m="$CHY_ROOT/db/installed/dbp/manifest"
expected=$(printf 'usr/bin/alpha\nusr/bin/zeta\nusr/share/dbp/x')
assert_eq "$(cat "$m")" "$expected" \
    'manifest is sorted, root-relative, files only'
while read -r line; do
    case $line in
        /*) fail "manifest line is absolute: $line" ;;
    esac
    [ -h "$CHY_ROOT/$line" ] || fail "manifest line is not a farm symlink: $line"
done <"$m"

# --- revision defaults to 1; no depends file appears uninvited ---
mkpkg "$CHY_ROOT" defp 1.0 usr/bin/defp-tool
run_chy install defp
assert_rc 0 'defp install'
assert_eq "$(cat "$CHY_ROOT/db/installed/defp/version")" '1.0 1' \
    'revision defaults to 1'
assert_absent "$CHY_ROOT/db/installed/defp/depends"

# --- depends is copied verbatim, comments and blanks included ---
mkpkg "$CHY_ROOT" depp 2.0 usr/bin/depp-tool
printf 'zlib\n\n# build note\nopenssl\n' >"$CHY_ROOT/recipes/depp/depends"
run_chy install depp
assert_rc 0 'depp install'
[ -f "$CHY_ROOT/db/installed/depp/depends" ] || fail 'depends not copied to db'
assert_eq "$(sha_of "$CHY_ROOT/db/installed/depp/depends")" \
    "$(sha_of "$CHY_ROOT/recipes/depp/depends")" 'depends copied verbatim'

# --- presence of db/installed/<name> is the definition of installed ---
run_chy list dbp defp depp
assert_rc 0
assert_eq "$(cat "$OUT")" "$(printf 'dbp 4.2 7\ndefp 1.0 1\ndepp 2.0 1')" \
    'list reflects the db entries exactly'

exit 0
