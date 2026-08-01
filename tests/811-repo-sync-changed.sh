#!/bin/sh
# 811: the scheduled default-repo sync machinery, changed day.
#
# The repo checkout holds a stale zlib version, so a clean translate
# stages exactly one change set: repo-sync.sh writes the pinned commit
# message (provenance from the golden MANIFEST, counts from the report,
# RUN_URL placeholder), repo-apply.sh commits as github-actions[bot]
# and pushes to the bare remote. Then: every recipes/*/build committed
# 100755 (mode stability), and a second sync is `unchanged`
# (idempotence).
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

git init -q --bare "$TMPD/repo.git"
git -C "$TMPD/repo.git" symbolic-ref HEAD refs/heads/main
git clone -q "$TMPD/repo.git" "$TMPD/repo" 2>/dev/null
git -C "$TMPD/repo" symbolic-ref HEAD refs/heads/main
cp -R "$g/expected/recipes" "$TMPD/repo/recipes"
for f in shlibs.map provided.suggested report TRANSLATOR_VERSION min-chy; do
    cp "$g/expected/$f" "$TMPD/repo/$f"
done
printf 'chy default repo (generated)\n' >"$TMPD/repo/README.md"
chmod 755 "$TMPD/repo"/recipes/*/build
printf '0.0 1\n' >"$TMPD/repo/recipes/zlib/version"   # the staleness
git -C "$TMPD/repo" add -A
git -C "$TMPD/repo" -c user.name=seed -c user.email=seed@test \
    commit -qm 'seed: golden repo, stale zlib'
git -C "$TMPD/repo" push -q origin HEAD:main

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

# --- sync: the staged diff demands a commit, message pinned ---
run sh ci/repo-sync.sh --snapshot "$g/snapshot" --repo "$TMPD/repo" \
    --set "$g/names" --decisions "$TMPD/dec" --translator translator
assert_rc 0 'sync on a changed repo'
assert_absent "$TMPD/dec/nochange"
[ -f "$TMPD/dec/commit.msg" ] || fail 'commit.msg missing on a changed day'
# subject provenance: common/shlibs commit and repodata digest of the
# committed golden MANIFEST, both truncated to 12 hex
file_matches "$TMPD/dec/commit.msg" \
    '^sync to void @ [0-9a-f]\{12\}, repodata slice [0-9a-f]\{12\}$'
assert_eq "$(head -n 1 "$TMPD/dec/commit.msg")" \
    'sync to void @ 665530c3d320, repodata slice 18fbc0dcf949' \
    'pinned commit subject'
file_has_line "$TMPD/dec/commit.msg" 'translated 19, exceptions 1, refused 0'
file_has_line "$TMPD/dec/commit.msg" 'run: RUN_URL'

# --- apply: one bot-authored commit lands on the bare remote ---
head0=$(git -C "$TMPD/repo.git" rev-parse refs/heads/main)
run sh ci/repo-apply.sh --decisions "$TMPD/dec" --repo "$TMPD/repo" \
    --issue-repo alperien/chy --gh "$TMPD/bin/gh"
assert_rc 0 'apply on a changed verdict'
head1=$(git -C "$TMPD/repo.git" rev-parse refs/heads/main)
[ "$head0" != "$head1" ] || fail 'bare HEAD did not move on a changed day'
assert_eq "$(git -C "$TMPD/repo.git" log -1 --format='%an <%ae>' refs/heads/main)" \
    'github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>' \
    'commit identity'
assert_eq "$(git -C "$TMPD/repo.git" log -1 --format=%s refs/heads/main)" \
    'sync to void @ 665530c3d320, repodata slice 18fbc0dcf949' \
    'pushed commit subject'
# gh: one listing for the auto-close scan, nothing mutating
assert_eq "$(count_matches '^issue list ' "$TMPD/gh.log")" 1 'one issue listing'
assert_eq "$(count_matches '^issue \(create\|comment\|close\|edit\) ' "$TMPD/gh.log")" 0 \
    'no mutating gh calls'

# --- mode stability: every build script is 100755, in index and remote ---
n=$(git -C "$TMPD/repo" ls-files -s \
    | awk '$4 ~ /^recipes\/[^\/]*\/build$/ { print $1 }' | sort -u)
assert_eq "$n" 100755 'index modes of recipes/*/build'
n=$(git -C "$TMPD/repo" ls-files -s \
    | awk '$4 ~ /^recipes\/[^\/]*\/build$/' | wc -l)
assert_eq "$n" 20 'twenty build scripts staged'
n=$(git -C "$TMPD/repo.git" ls-tree -r refs/heads/main \
    | awk '$4 ~ /^recipes\/[^\/]*\/build$/ { print $1 }' | sort -u)
assert_eq "$n" 100755 'pushed modes of recipes/*/build'

# --- idempotence: the very next sync is an unchanged day ---
run sh ci/repo-sync.sh --snapshot "$g/snapshot" --repo "$TMPD/repo" \
    --set "$g/names" --decisions "$TMPD/dec" --translator translator
assert_rc 0 're-sync after the push'
assert_eq "$(cat "$TMPD/dec/nochange")" unchanged 're-sync verdict'
assert_absent "$TMPD/dec/commit.msg"

exit 0
