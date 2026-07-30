#!/bin/sh
# 814: recovery auto-close.
#
# The stub's canned list shows two open refusal issues: zlib (in the set,
# translating cleanly again) and notinset (not in this repo at all).
# A clean changed run pushes, and corpus-apply.sh must close exactly the
# issue whose package the freshly committed report shows translated:
# one `issue close` for zlib, nothing for notinset, no creates.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

for t in git python3 bash; do
    command -v "$t" >/dev/null 2>&1 || { echo "SKIP: $t unavailable"; exit 0; }
done

t_init
umask 022
g=translator/tests/golden

git init -q --bare "$TMPD/corpus.git"
git -C "$TMPD/corpus.git" symbolic-ref HEAD refs/heads/main
git clone -q "$TMPD/corpus.git" "$TMPD/corpus" 2>/dev/null
git -C "$TMPD/corpus" symbolic-ref HEAD refs/heads/main
cp -R "$g/expected/recipes" "$TMPD/corpus/recipes"
for f in shlibs.map provided.suggested report TRANSLATOR_VERSION; do
    cp "$g/expected/$f" "$TMPD/corpus/$f"
done
printf 'chy default repo (generated)\n' >"$TMPD/corpus/README.md"
chmod 755 "$TMPD/corpus"/recipes/*/build
# the stale recipe a past refusal kept pinned; today's run replaces it
printf '0.0 1\n' >"$TMPD/corpus/recipes/zlib/version"
git -C "$TMPD/corpus" add -A
git -C "$TMPD/corpus" -c user.name=seed -c user.email=seed@test \
    commit -qm 'seed: golden repo, stale zlib'
git -C "$TMPD/corpus" push -q origin HEAD:main

mkdir -p "$TMPD/bin"
: >"$TMPD/gh.log"
zeros=$(printf '%064d' 0)
printf '[{"number":3,"title":"corpus-sync: refused: zlib","body":"reason-hash: %s"},
 {"number":4,"title":"corpus-sync: refused: notinset","body":"reason-hash: %s"}]\n' \
    "$zeros" "$zeros" >"$TMPD/issues.json"
cat >"$TMPD/bin/gh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$TMPD/gh.log"
case "\$1 \${2:-}" in
    'issue list') cat "$TMPD/issues.json" ;;
esac
EOF
chmod 755 "$TMPD/bin/gh"

# --- a clean changed run: translate, stage, prepare the commit ---
run sh ci/corpus-sync.sh --snapshot "$g/snapshot" --corpus "$TMPD/corpus" \
    --set "$g/names" --decisions "$TMPD/dec" --translator translator
assert_rc 0 'clean sync'
[ -f "$TMPD/dec/commit.msg" ] || fail 'commit.msg missing on the recovery day'
assert_absent "$TMPD/dec/issues"

# --- apply: push, then close the recovered refusal and only it ---
head0=$(git -C "$TMPD/corpus.git" rev-parse refs/heads/main)
run sh ci/corpus-apply.sh --decisions "$TMPD/dec" --corpus "$TMPD/corpus" \
    --issue-repo alperien/chy --gh "$TMPD/bin/gh"
assert_rc 0 'apply on the recovery day'
[ "$(git -C "$TMPD/corpus.git" rev-parse refs/heads/main)" != "$head0" ] \
    || fail 'the recovery run did not push'
assert_eq "$(count_matches '^issue close ' "$TMPD/gh.log")" 1 'exactly one close'
assert_eq "$(count_matches '^issue close 3 ' "$TMPD/gh.log")" 1 'closed the zlib issue'
file_matches "$TMPD/gh.log" '^issue close 3 --repo alperien/chy --comment '
assert_eq "$(count_matches '^issue \(create\|comment\|edit\) ' "$TMPD/gh.log")" 0 \
    'no creates, comments, or edits'
grep -q '^issue close 4 ' "$TMPD/gh.log" \
    && fail 'closed an issue whose package is not in the repo'

exit 0
