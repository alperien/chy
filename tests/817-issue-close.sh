#!/bin/sh
# 817: closing the issues a run resolves (ci/repo-apply.sh).
#
# A staged day commits and pushes; the stub gh serves a canned open
# list covering every close decision. apply runs from a scratch ci/
# copy whose sibling default.set is this test's own, so set membership
# is pinned, not inherited from the real set:
#   newok    build-failed issue, recipe ships in the commit   -> closed
#   flaky    refused issue, ships, but its close fails        -> attempted,
#                                                               warned, rc 0
#   zlib     build-failed issue AND today's decisions hold a
#            build-zlib.md while the diff carries it          -> stays open
#   ghostpkg build-failed, not in the set, not shipped        -> swept
#   orphan   build-failed, not in the set yet shipped today   -> closed once
#                                                               by the ship
#                                                               loop, never twice
#   ghostref refused, not in the set                          -> NOT swept
#   #10      unrelated title                                  -> untouched
# Coda: the same apply from a copy with no sibling default.set skips
# the sweep silently (ghostpkg survives) while shipping closes fire.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

for t in git python3; do
    command -v "$t" >/dev/null 2>&1 || { echo "SKIP: $t unavailable"; exit 0; }
done

t_init
umask 022
zeros=$(printf '%064d' 0)

# --- hermetic script homes: one beside a pinned default.set, one
#     beside nothing ---
mkdir -p "$TMPD/withset/ci" "$TMPD/noset/ci"
cp ci/repo-apply.sh "$TMPD/withset/ci/repo-apply.sh"
printf 'keep\nzlib\nnewok\nflaky\n' >"$TMPD/withset/default.set"
cp ci/repo-apply.sh "$TMPD/noset/ci/repo-apply.sh"

# --- the repo: bare origin plus a checkout seeded with keep and a
#     stale zlib; none of these names are real packages ---
git init -q --bare "$TMPD/repo.git"
git -C "$TMPD/repo.git" symbolic-ref HEAD refs/heads/main
git clone -q "$TMPD/repo.git" "$TMPD/repo" 2>/dev/null
git -C "$TMPD/repo" symbolic-ref HEAD refs/heads/main
mkdir -p "$TMPD/repo/recipes/keep" "$TMPD/repo/recipes/zlib"
printf '1.0 1\n' >"$TMPD/repo/recipes/keep/version"
printf '0.0 1\n' >"$TMPD/repo/recipes/zlib/version"
: >"$TMPD/repo/provided.suggested"
: >"$TMPD/repo/shlibs.map"
printf 'translated: keep\n' >"$TMPD/repo/report"
git -C "$TMPD/repo" add -A
git -C "$TMPD/repo" -c user.name=seed -c user.email=seed@test \
    commit -qm 'seed: prior repo state'
git -C "$TMPD/repo" push -q origin HEAD:main

# --- the day: newok, flaky and orphan are added, zlib bumps; zlib
#     also has a live build issue in today's decisions (the hold
#     precedence). orphan rides no set line: only the ship loop may
#     close it, and it must do so exactly once ---
mkdir -p "$TMPD/repo/recipes/newok" "$TMPD/repo/recipes/flaky" \
    "$TMPD/repo/recipes/orphan"
printf '1.0 1\n' >"$TMPD/repo/recipes/newok/version"
printf '1.0 1\n' >"$TMPD/repo/recipes/flaky/version"
printf '1.0 1\n' >"$TMPD/repo/recipes/orphan/version"
printf '2.0 1\n' >"$TMPD/repo/recipes/zlib/version"
git -C "$TMPD/repo" add -A
mkdir -p "$TMPD/dec/issues"
printf 'sync to void @ deadbeefcafe, repodata slice cafebabefeed\n' \
    >"$TMPD/dec/commit.msg"
{
    printf 'The build gate held zlib: it failed to build.\n\n'
    printf 'reason-hash: %s\n' "$zeros"
} >"$TMPD/dec/issues/build-zlib.md"

mkdir -p "$TMPD/bin"
: >"$TMPD/gh.log"
printf '[{"number":5,"title":"repo-sync: build failed: newok","body":"reason-hash: 0"},
 {"number":6,"title":"repo-sync: refused: flaky","body":"reason-hash: 0"},
 {"number":7,"title":"repo-sync: build failed: zlib","body":"reason-hash: %s"},
 {"number":8,"title":"repo-sync: build failed: ghostpkg","body":"reason-hash: 0"},
 {"number":11,"title":"repo-sync: build failed: orphan","body":"reason-hash: 0"},
 {"number":9,"title":"repo-sync: refused: ghostref","body":"reason-hash: 0"},
 {"number":10,"title":"repo-sync: doctor found problems","body":""}]
' "$zeros" >"$TMPD/issues.json"
cat >"$TMPD/bin/gh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$TMPD/gh.log"
case "\$1 \$2 \$3" in
    'issue close 6') exit 1 ;;
esac
case "\$1 \$2" in
    'issue list') cat "$TMPD/issues.json" ;;
esac
EOF
chmod 755 "$TMPD/bin/gh"

# --- apply: push, then close exactly what the run resolves ---
head0=$(git -C "$TMPD/repo.git" rev-parse refs/heads/main)
run sh "$TMPD/withset/ci/repo-apply.sh" --decisions "$TMPD/dec" \
    --repo "$TMPD/repo" --issue-repo alperien/chy --gh "$TMPD/bin/gh"
assert_rc 0 'apply closes what the run resolves'
[ "$(git -C "$TMPD/repo.git" rev-parse refs/heads/main)" != "$head0" ] \
    || fail 'the day did not push'
assert_eq "$(count_matches '^issue close 5 ' "$TMPD/gh.log")" 1 \
    'a shipped name with an open build issue gets closed'
assert_eq "$(count_matches '^issue close 6 ' "$TMPD/gh.log")" 1 \
    'the failing close was attempted'
assert_eq "$(count_matches '^issue close 7 ' "$TMPD/gh.log")" 0 \
    'a name still failing this run stays open'
assert_eq "$(count_matches '^issue close 8 ' "$TMPD/gh.log")" 1 \
    'a name gone from default.set gets swept'
assert_eq "$(count_matches '^issue close 11 ' "$TMPD/gh.log")" 1 \
    'a shipped name outside the set closes exactly once'
assert_eq "$(count_matches '^issue close 9 ' "$TMPD/gh.log")" 0 \
    'refused issues are never swept'
assert_eq "$(count_matches '^issue close 10 ' "$TMPD/gh.log")" 0 \
    'unrelated issues are untouched'
assert_eq "$(count_matches '^issue close ' "$TMPD/gh.log")" 4 \
    'exactly four close attempts'
assert_eq "$(count_matches '^issue \(create\|comment\|edit\) ' "$TMPD/gh.log")" 0 \
    'dedup stays silent: matching hash, no new issues'
file_has_line "$OUT" 'repo-apply: closed: repo-sync: build failed: newok'
file_has_line "$OUT" 'repo-apply: warn: close failed: repo-sync: refused: flaky'
file_has_line "$OUT" 'repo-apply: swept: repo-sync: build failed: ghostpkg'
file_matches "$TMPD/gh.log" \
    '^issue close 5 --repo alperien/chy --comment repo-sync: newok shipped in this push; closing.$'
file_matches "$TMPD/gh.log" \
    '^issue close 8 --repo alperien/chy --comment repo-sync: ghostpkg is no longer in default.set; closing.$'

# --- coda: no default.set next to the script, no sweep. A second day
#     bumps newok and flaky only; the ship loop still closes them,
#     ghostpkg survives ---
printf '4.0 1\n' >"$TMPD/repo/recipes/newok/version"
printf '2.0 1\n' >"$TMPD/repo/recipes/flaky/version"
git -C "$TMPD/repo" add -A
rm -rf "$TMPD/dec2"
mkdir -p "$TMPD/dec2"
printf 'sync to void @ deadbeefcafe, repodata slice cafebabefeed\n' \
    >"$TMPD/dec2/commit.msg"
: >"$TMPD/gh.log"
head1=$(git -C "$TMPD/repo.git" rev-parse refs/heads/main)
run sh "$TMPD/noset/ci/repo-apply.sh" --decisions "$TMPD/dec2" \
    --repo "$TMPD/repo" --issue-repo alperien/chy --gh "$TMPD/bin/gh"
assert_rc 0 'apply without a default.set'
[ "$(git -C "$TMPD/repo.git" rev-parse refs/heads/main)" != "$head1" ] \
    || fail 'the second day did not push'
assert_eq "$(count_matches '^issue close 5 ' "$TMPD/gh.log")" 1 \
    'shipping closes still fire without a set file'
assert_eq "$(count_matches '^issue close 8 ' "$TMPD/gh.log")" 0 \
    'the sweep is skipped when default.set is absent'
assert_eq "$(count_matches '^issue close ' "$TMPD/gh.log")" 2 \
    'only the shipped names were closed'

exit 0
