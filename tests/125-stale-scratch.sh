#!/bin/sh
# An interrupted run can leave the build scratch in a bad shape:
# build/srcs left as a directory, or build itself a regular file.
# fetch_all is the only place a source checksum gets verified, so if a
# stale scratch made its writes fail silently the loop would run zero
# times and the build would go on from unverified cache. Every write in
# fetch_all is checked, a stale scratch now fails the install loudly.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

# build/srcs left as a directory by an interrupted run
mkpkg "$CHY_ROOT" pkg 1.0 usr/bin/tool
mkdir -p "$CHY_ROOT/build/srcs"
run_chy install pkg
assert_rc 1 'a stale build/srcs directory fails the install'
file_has "$ERR" 'source list'
assert_not_installed "$CHY_ROOT" pkg

# build left as a regular file
rm -rf "$CHY_ROOT/build"
: >"$CHY_ROOT/build"
run_chy install pkg
assert_rc 1 'a stale build regular file fails the install'
assert_not_installed "$CHY_ROOT" pkg

exit 0
