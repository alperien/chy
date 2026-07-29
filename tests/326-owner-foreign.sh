#!/bin/sh
# owner_of decides whether a farm link is ours by its target. chy's own
# links look like (../)*store/<name>/... . A foreign link whose target
# just passes through some directory named store followed by the
# package name must NOT be claimed: remove leaves it in place and says
# so, it won't delete a path chy never created.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

t_init

mkpkg "$CHY_ROOT" app 1.0 usr/bin/tool
run_chy install app
assert_rc 0 'app installs'
assert_link "$CHY_ROOT/usr/bin/tool" '../../store/app/usr/bin/tool'

# a user replaces the farm link with a foreign one (a backup mount) whose
# target contains a /store/app/ component but is not chy's own link
rm -f "$CHY_ROOT/usr/bin/tool"
ln -s "../../mnt/backup/store/app/usr/bin/tool" "$CHY_ROOT/usr/bin/tool"

run_chy remove app
assert_rc 0 'remove still succeeds'
[ -h "$CHY_ROOT/usr/bin/tool" ] || fail 'the foreign link was deleted, not left in place'
file_has "$ERR" 'left in place'
assert_not_installed "$CHY_ROOT" app

exit 0
