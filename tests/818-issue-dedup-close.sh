#!/bin/sh
# 818: closing legacy duplicate issues when a title is filed (ci/repo-apply.sh).
#
# ~2714 open build-failed issues exist for ~285 held names: duplicates
# minted while the issue listing was capped at 200 and dedup could not
# see the old ones. Whatever the filing loop now does with the
# issue_row-picked issue (silence on an unchanged reason-hash, or
# comment + body refresh on a changed one), every OTHER open issue with
# the same repo-sync: title must be closed with a duplicate comment.
# Hermetic like 813/817: a stub gh serves a canned issues.tsv source,
# gh.log pins every call. Cases:
#   foo      three open `repo-sync: build failed: foo` issues; a changed
#            reason-hash comments+edits the kept one and closes #2, #3
#   bar      same three duplicates but the hash is unchanged: the kept
#            one stays silent, the duplicates still close
#   solo     one open issue, filed again: zero closes
#   dud      the duplicate close fails: warn, rc stays 0
#   doctor   an unrelated repo-sync title with lookalike numbers is
#            never touched; day-2 refiling exercises dedup on the
#            changed-hash path without touching anything else
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
ones=$(printf '%064d' 1)

# --- hermetic script home; the real ci/repo-apply.sh, stub gh beside it ---
mkdir -p "$TMPD/ci" "$TMPD/bin" "$TMPD/dec/issues"
cp ci/repo-apply.sh "$TMPD/ci/repo-apply.sh"
: >"$TMPD/gh.log"

# --- decisions: a build failure for foo and one for bar (unchanged-hash
#     case, seeded to match), a solo one, and a dud one for the failing
#     close. The repo is a bare origin; nothing pushes, only the issue
#     lifecycle runs. ---
printf 'build failed\n\nreason-hash: %s\n' "$ones" >"$TMPD/dec/issues/build-foo.md"
printf 'build failed\n\nreason-hash: %s\n' "$zeros" >"$TMPD/dec/issues/build-bar.md"
printf 'build failed\n\nreason-hash: %s\n' "$zeros" >"$TMPD/dec/issues/build-solo.md"
printf 'build failed\n\nreason-hash: %s\n' "$zeros" >"$TMPD/dec/issues/build-dud.md"

git init -q --bare "$TMPD/repo.git"
git -C "$TMPD/repo.git" symbolic-ref HEAD refs/heads/main
git clone -q "$TMPD/repo.git" "$TMPD/repo" 2>/dev/null
git -C "$TMPD/repo" symbolic-ref HEAD refs/heads/main
: >"$TMPD/repo/provided.suggested"
: >"$TMPD/repo/shlibs.map"
printf 'translated: nothing\n' >"$TMPD/repo/report"
git -C "$TMPD/repo" add -A
git -C "$TMPD/repo" -c user.name=seed -c user.email=seed@test \
    commit -qm 'seed: empty repo'
git -C "$TMPD/repo" push -q origin HEAD:main

# --- the canned open list: three foos, three bars, a solo, a dud, and
#     an unrelated doctor issue whose number contains the same digits
printf '[{"number":1,"title":"repo-sync: build failed: foo","body":"reason-hash: %s"},
 {"number":2,"title":"repo-sync: build failed: foo","body":"reason-hash: %s"},
 {"number":3,"title":"repo-sync: build failed: foo","body":"reason-hash: %s"},
 {"number":4,"title":"repo-sync: build failed: bar","body":"reason-hash: %s"},
 {"number":5,"title":"repo-sync: build failed: bar","body":"reason-hash: %s"},
 {"number":6,"title":"repo-sync: build failed: bar","body":"reason-hash: %s"},
 {"number":7,"title":"repo-sync: build failed: solo","body":"reason-hash: %s"},
 {"number":8,"title":"repo-sync: build failed: dud","body":"reason-hash: %s"},
 {"number":9,"title":"repo-sync: build failed: dud","body":"reason-hash: %s"},
 {"number":23,"title":"repo-sync: doctor found problems","body":""},
 {"number":31,"title":"something else entirely","body":""}]
' "$zeros" "$ones" "$ones" "$zeros" "$zeros" "$zeros" "$zeros" "$zeros" "$zeros" \
    >"$TMPD/issues.json"
cat >"$TMPD/bin/gh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$TMPD/gh.log"
case "\$1 \$2 \$3" in
    'issue close 9') exit 1 ;;
esac
case "\$1 \$2" in
    'issue list') cat "$TMPD/issues.json" ;;
esac
EOF
chmod 755 "$TMPD/bin/gh"

# --- day 1: changed hash for foo (kept #1 gets comment+edit), matching
#     hash for bar/solo/dud; duplicates of foo and bar close, dud warns ---
run env PATH="$TMPD/bin:$PATH" sh "$TMPD/ci/repo-apply.sh" \
    --decisions "$TMPD/dec" --repo "$TMPD/repo" \
    --issue-repo alperien/chy --gh "$TMPD/bin/gh"
assert_rc 0 'apply runs clean with failing duplicate closes'
assert_eq "$(count_matches '^issue close 2 ' "$TMPD/gh.log")" 1 \
    'first duplicate of foo closed'
assert_eq "$(count_matches '^issue close 3 ' "$TMPD/gh.log")" 1 \
    'second duplicate of foo closed'
assert_eq "$(count_matches '^issue close 1 ' "$TMPD/gh.log")" 0 \
    'the kept foo issue is never closed by dedup'
assert_eq "$(count_matches '^issue comment 1 ' "$TMPD/gh.log")" 1 \
    'changed hash comments the kept foo issue'
assert_eq "$(count_matches '^issue edit 1 ' "$TMPD/gh.log")" 1 \
    'changed hash refreshes the kept foo issue'
assert_eq "$(count_matches '^issue close 5 ' "$TMPD/gh.log")" 1 \
    'duplicate of bar closed despite unchanged hash'
assert_eq "$(count_matches '^issue close 6 ' "$TMPD/gh.log")" 1 \
    'second duplicate of bar closed'
assert_eq "$(count_matches '^issue comment 4 ' "$TMPD/gh.log")" 0 \
    'unchanged hash leaves the kept bar issue silent'
assert_eq "$(count_matches '^issue close 7 ' "$TMPD/gh.log")" 0 \
    'a single issue is filed, not closed'
assert_eq "$(count_matches '^issue close 8 ' "$TMPD/gh.log")" 0 \
    'the kept dud issue is not closed'
assert_eq "$(count_matches '^issue close 9 ' "$TMPD/gh.log")" 1 \
    'the failing duplicate close was attempted'
assert_eq "$(count_matches '^issue close 23 ' "$TMPD/gh.log")" 0 \
    'unrelated repo-sync title untouched'
assert_eq "$(count_matches '^issue close 31 ' "$TMPD/gh.log")" 0 \
    'non repo-sync title untouched'
assert_eq "$(count_matches '^issue close ' "$TMPD/gh.log")" 5 \
    'exactly five duplicate closes attempted'
file_matches "$TMPD/gh.log" \
    '^issue close 2 --repo alperien/chy --comment repo-sync: duplicate of #1; closing.$'
file_matches "$TMPD/gh.log" \
    '^issue close 6 --repo alperien/chy --comment repo-sync: duplicate of #4; closing.$'
file_has_line "$OUT" 'repo-apply: closed duplicate: repo-sync: build failed: foo'
file_has_line "$OUT" 'repo-apply: warn: duplicate close failed: repo-sync: build failed: dud'

# --- day 2: every decision hash matches its kept issue; the closed
#     duplicates stay closed. Absolute silence, zero gh writes ---
: >"$TMPD/gh.log"
# the stub serves a canned list; model day 1's effect: the duplicates
# are closed, the kept foo body carries the reason it was refreshed with
printf '[{"number":1,"title":"repo-sync: build failed: foo","body":"reason-hash: %s"},
 {"number":4,"title":"repo-sync: build failed: bar","body":"reason-hash: %s"},
 {"number":7,"title":"repo-sync: build failed: solo","body":"reason-hash: %s"},
 {"number":8,"title":"repo-sync: build failed: dud","body":"reason-hash: %s"},
 {"number":23,"title":"repo-sync: doctor found problems","body":""},
 {"number":31,"title":"something else entirely","body":""}]
' "$ones" "$zeros" "$zeros" "$zeros" >"$TMPD/issues.json"
run env PATH="$TMPD/bin:$PATH" sh "$TMPD/ci/repo-apply.sh" \
    --decisions "$TMPD/dec" --repo "$TMPD/repo" \
    --issue-repo alperien/chy --gh "$TMPD/bin/gh"
assert_rc 0 'day 2 apply runs clean'
assert_eq "$(count_matches '^issue close ' "$TMPD/gh.log")" 0 \
    'closed duplicates are not re-closed on a later day'
assert_eq "$(count_matches '^issue comment ' "$TMPD/gh.log")" 0 \
    'kept issues stay silent once the hash matches'
assert_eq "$(count_matches '^issue create ' "$TMPD/gh.log")" 0 \
    'no new issues filed while the kept ones are open'

# --- day 3: bar's reason changes. The kept #4 gets comment + edit, and
#     dedup finds no open duplicate left to close ---
: >"$TMPD/gh.log"
printf 'build failed\n\nreason-hash: %s\n' "$ones" >"$TMPD/dec/issues/build-bar.md"
printf '[{"number":1,"title":"repo-sync: build failed: foo","body":"reason-hash: %s"},
 {"number":4,"title":"repo-sync: build failed: bar","body":"reason-hash: %s"},
 {"number":7,"title":"repo-sync: build failed: solo","body":"reason-hash: %s"},
 {"number":8,"title":"repo-sync: build failed: dud","body":"reason-hash: %s"},
 {"number":23,"title":"repo-sync: doctor found problems","body":""},
 {"number":31,"title":"something else entirely","body":""}]
' "$ones" "$zeros" "$zeros" "$zeros" >"$TMPD/issues.json"
run env PATH="$TMPD/bin:$PATH" sh "$TMPD/ci/repo-apply.sh" \
    --decisions "$TMPD/dec" --repo "$TMPD/repo" \
    --issue-repo alperien/chy --gh "$TMPD/bin/gh"
assert_rc 0 'day 3 apply runs clean'
assert_eq "$(count_matches '^issue comment 4 ' "$TMPD/gh.log")" 1 \
    'changed hash comments the kept bar issue'
assert_eq "$(count_matches '^issue edit 4 ' "$TMPD/gh.log")" 1 \
    'changed hash refreshes the kept bar issue'
assert_eq "$(count_matches '^issue close ' "$TMPD/gh.log")" 0 \
    'no duplicate left to close'
assert_eq "$(count_matches '^issue create ' "$TMPD/gh.log")" 0 \
    'no new issues filed'

exit 0
