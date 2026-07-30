#!/bin/sh
# 810: the scheduled default-repo sync machinery, unchanged day.
#
# A bare local repo plays the remote; its clone is seeded with the
# committed golden expected recipes (with the modes a real bot push
# carries: translate emits build scripts 0755). Translating the golden
# snapshot over the golden set then moves nothing: repo-sync.sh records
# `unchanged` and no commit.msg, repo-apply.sh pushes nothing and makes
# zero gh calls. Coda: repo-verify-lock.sh against canned rulesets
# JSON, locked and two loosened flavors.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

for t in git python3 bash; do
    command -v "$t" >/dev/null 2>&1 || { echo "SKIP: $t unavailable"; exit 0; }
done

t_init
umask 022   # the fixture is mode-sensitive
g=translator/tests/golden

# --- fake repo remote: bare repo, clone, golden content, one commit ---
git init -q --bare "$TMPD/repo.git"
git -C "$TMPD/repo.git" symbolic-ref HEAD refs/heads/main
git clone -q "$TMPD/repo.git" "$TMPD/repo" 2>/dev/null
git -C "$TMPD/repo" symbolic-ref HEAD refs/heads/main
cp -R "$g/expected/recipes" "$TMPD/repo/recipes"
for f in shlibs.map provided.suggested report TRANSLATOR_VERSION; do
    cp "$g/expected/$f" "$TMPD/repo/$f"
done
printf 'chy default repo (generated)\n' >"$TMPD/repo/README.md"
chmod 755 "$TMPD/repo"/recipes/*/build
git -C "$TMPD/repo" add -A
git -C "$TMPD/repo" -c user.name=seed -c user.email=seed@test \
    commit -qm 'seed: golden repo'
git -C "$TMPD/repo" push -q origin HEAD:main

# --- PATH-shim gh: logs argv, serves canned issue-list JSON ---
mkdir -p "$TMPD/bin"
printf '[]\n' >"$TMPD/issues.json"
: >"$TMPD/gh.log"
cat >"$TMPD/bin/gh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$TMPD/gh.log"
case "\$1 \${2:-}" in
    'issue list') cat "$TMPD/issues.json" ;;
esac
EOF
chmod 755 "$TMPD/bin/gh"

# --- sync: byte-identical translation, so the verdict is `unchanged` ---
run sh ci/repo-sync.sh --snapshot "$g/snapshot" --repo "$TMPD/repo" \
    --set "$g/names" --decisions "$TMPD/dec" --translator translator
assert_rc 0 'sync on an unchanged repo'
assert_eq "$(cat "$TMPD/dec/nochange")" unchanged 'nochange verdict'
assert_absent "$TMPD/dec/commit.msg"
assert_absent "$TMPD/dec/issues"
[ -z "$(git -C "$TMPD/repo" status --porcelain)" ] \
    || fail 'sync left the checkout dirty on an unchanged day'

# --- apply: nothing staged, nothing pushed, gh never consulted ---
head0=$(git -C "$TMPD/repo.git" rev-parse refs/heads/main)
run sh ci/repo-apply.sh --decisions "$TMPD/dec" --repo "$TMPD/repo" \
    --issue-repo alperien/chy --gh "$TMPD/bin/gh"
assert_rc 0 'apply on an unchanged verdict'
file_has_line "$OUT" 'repo-apply: nothing to apply'
assert_eq "$(git -C "$TMPD/repo.git" rev-parse refs/heads/main)" "$head0" \
    'bare HEAD moved on an unchanged day'
assert_empty_file "$TMPD/gh.log" 'gh calls on an unchanged day'

# --- coda: repo-verify-lock.sh on canned api JSON ---
cat >"$TMPD/rules.json" <<'EOF'
[{"type":"update","ruleset_id":9},{"type":"deletion","ruleset_id":9},
 {"type":"non_fast_forward","ruleset_id":9}]
EOF
cat >"$TMPD/ruleset.json" <<'EOF'
{"id":9,"enforcement":"active",
 "bypass_actors":[{"actor_id":0,"actor_type":"DeployKey","bypass_mode":"always"}]}
EOF
cat >"$TMPD/bin/ghapi" <<EOF
#!/bin/sh
[ "\$1" = api ] || exit 64
case "\$2" in
    repos/alperien/chy-corpus) printf '{"default_branch":"main"}\n' ;;
    repos/alperien/chy-corpus/rules/branches/main) cat "$TMPD/rules.json" ;;
    repos/alperien/chy-corpus/rulesets/9) cat "$TMPD/ruleset.json" ;;
    *) exit 64 ;;
esac
EOF
chmod 755 "$TMPD/bin/ghapi"

run sh ci/repo-verify-lock.sh --repo alperien/chy-corpus \
    --gh "$TMPD/bin/ghapi"
assert_rc 0 'verify-lock accepts the pinned ruleset'
file_has "$OUT" 'locked'

# loosened flavor 1: a second bypass actor sneaks in
cat >"$TMPD/ruleset.json" <<'EOF'
{"id":9,"enforcement":"active",
 "bypass_actors":[{"actor_id":0,"actor_type":"DeployKey","bypass_mode":"always"},
                  {"actor_id":1,"actor_type":"Integration","bypass_mode":"always"}]}
EOF
run sh ci/repo-verify-lock.sh --repo alperien/chy-corpus \
    --gh "$TMPD/bin/ghapi" --decisions "$TMPD/dec-lock"
assert_rc 2 'a loosened bypass list must not pass'
file_has "$ERR" 'bypass actors'
file_has "$TMPD/dec-lock/issues/lock.md" 'bypass actors'
file_matches "$TMPD/dec-lock/issues/lock.md" '^reason-hash: [0-9a-f]\{64\}$'

# loosened flavor 2: a required rule gone entirely
cat >"$TMPD/ruleset.json" <<'EOF'
{"id":9,"enforcement":"active",
 "bypass_actors":[{"actor_id":0,"actor_type":"DeployKey","bypass_mode":"always"}]}
EOF
cat >"$TMPD/rules.json" <<'EOF'
[{"type":"update","ruleset_id":9},{"type":"non_fast_forward","ruleset_id":9}]
EOF
run sh ci/repo-verify-lock.sh --repo alperien/chy-corpus \
    --gh "$TMPD/bin/ghapi"
assert_rc 2 'a missing rule must not pass'
file_has "$ERR" 'missing rule: deletion'

exit 0
