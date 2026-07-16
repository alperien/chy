#!/bin/sh
# a version string with a + in it (openssl ships 3.x+quic, and git
# snapshots use it) has to validate and install like any other.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

mkpkg "$CHY_ROOT" plusver "1.4+20240101" usr/bin/pv-tool
run_chy install plusver
assert_rc 0 'a + in the version installs cleanly'
assert_installed "$CHY_ROOT" plusver "1.4+20240101" 1
assert_link "$CHY_ROOT/usr/bin/pv-tool" '../../store/plusver/usr/bin/pv-tool'

exit 0
