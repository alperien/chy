#!/bin/sh
# a backslash is legal in a root path (absolute, no whitespace, no . or
# .. components) and cache verification has to work there too. Host
# sha256sum escapes such filenames on its checksum line (a leading \
# before the digest), which once turned every install under such a root
# into a bogus checksum mismatch on "\<hash>" that also deleted the
# good cache seed.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

broot="$TMPD/bs\\root"
mkdir -p "$broot"
mkpkg "$broot" bspkg 1.0 usr/bin/bs-tool

# the recipe digest came from a backslash-free path. The cache copy's
# path has to trip sha256sum's escaping mode here, skip when it doesn't.
case $(sha256sum "$broot/cache/seed-bspkg.txt") in
    \\*) ;;
    *) echo 'SKIP: sha256sum does not escape backslash filenames'; exit 0 ;;
esac

run_chy_root "$broot" install bspkg
assert_rc 0 'install under a backslash root'
file_has_line "$OUT" '+ bspkg 1.0_1'
assert_installed "$broot" bspkg 1.0 1
assert_link "$broot/usr/bin/bs-tool" '../../store/bspkg/usr/bin/bs-tool'
assert_eq "$(cat "$broot/usr/bin/bs-tool")" \
    "$(pkg_content bspkg usr/bin/bs-tool)" 'farm link resolves to the built file'

# a verified cache hit keeps the seed, a misread digest would've
# deleted it and walked the unreachable URL
[ -f "$broot/cache/seed-bspkg.txt" ] || fail 'cache seed was deleted'
assert_eq "$(cat "$broot/cache/seed-bspkg.txt")" 'seed for bspkg' \
    'cache seed content intact'

exit 0
