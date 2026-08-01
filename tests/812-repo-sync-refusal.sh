#!/bin/sh
# 812: a refusal holds the package, the day proceeds.
#
# A copy of the golden snapshot gets one sabotaged template: appending
# build_style=waf (outside the allowlist) makes zlib a guaranteed
# refusal while the other nineteen translate. Holdback: zlib keeps the
# seeded recipe (never regenerated) and stays out of
# provided.suggested, repo-sync.sh writes issues/refused-zlib.md
# (verbatim reason, held state, pinned template commit, reason-hash),
# and the day still commits: the published report documents the hold.
# The identical day after is unchanged. A refused name with no prior
# recipe stays absent. repo-apply.sh files one issue per refusal and
# pushes the surviving diff. Coda: a missing snapshot is the infra
# decision.
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

# sabotaged snapshot copy; the committed golden stays untouched
cp -R "$g/snapshot" "$TMPD/snap"
printf 'build_style=waf\n' >>"$TMPD/snap/srcpkgs/zlib/template"

git init -q --bare "$TMPD/repo.git"
git -C "$TMPD/repo.git" symbolic-ref HEAD refs/heads/main
git clone -q "$TMPD/repo.git" "$TMPD/repo" 2>/dev/null
git -C "$TMPD/repo" symbolic-ref HEAD refs/heads/main
cp -R "$g/expected/recipes" "$TMPD/repo/recipes"
for f in shlibs.map provided.suggested report TRANSLATOR_VERSION min-chy; do
    cp "$g/expected/$f" "$TMPD/repo/$f"
done
printf 'chy default repo (generated)\n' >"$TMPD/repo/README.md"
# a handwritten recipe outside the set: it has to ride the wholesale
# regeneration untouched, even on a day that commits
mkdir -p "$TMPD/repo/recipes/hand1"
printf 'origin: handwritten\n' >"$TMPD/repo/recipes/hand1/meta"
printf '1.0 1\n' >"$TMPD/repo/recipes/hand1/version"
printf 'https://example.org/hand1.tar.gz\n' >"$TMPD/repo/recipes/hand1/sources"
printf 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n' \
    >"$TMPD/repo/recipes/hand1/checksums"
printf '# frozen fixture build\nexit 1\n' >"$TMPD/repo/recipes/hand1/build"
chmod 755 "$TMPD/repo"/recipes/*/build
git -C "$TMPD/repo" add -A
git -C "$TMPD/repo" -c user.name=seed -c user.email=seed@test \
    commit -qm 'seed: golden repo'
git -C "$TMPD/repo" push -q origin HEAD:main
hand0=$(sha256sum "$TMPD/repo/recipes/hand1/build" "$TMPD/repo/recipes/hand1/meta")

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

# --- sync 1: the refusal day. zlib holds; the diff is the report
#     documenting the hold, and nothing else ---
run sh ci/repo-sync.sh --snapshot "$TMPD/snap" --repo "$TMPD/repo" \
    --set "$g/names" --decisions "$TMPD/dec" --translator translator
assert_rc 0 'sync decides, it does not fail, on a refusal'
assert_absent "$TMPD/dec/nochange"
[ -f "$TMPD/dec/commit.msg" ] || fail 'a held day must still commit its report'
file_has "$TMPD/dec/commit.msg" 'refused 1'
md="$TMPD/dec/issues/refused-zlib.md"
[ -f "$md" ] || fail 'issues/refused-zlib.md missing'
assert_eq "$(find "$TMPD/dec/issues" -type f | wc -l)" 1 'exactly one issue decision'
# the verbatim reason (TRANSLATOR emit wording), held state, body fields
file_has "$md" "refused: zlib: build_style 'waf' is outside the allowlist"
file_has_line "$md" 'state: held at its last translated recipe'
tpl=$(awk -v want=/srcpkgs/zlib/template \
    'substr($1, length($1) - length(want) + 1) == want { print $2; exit }' \
    "$g/snapshot/MANIFEST")
[ -n "$tpl" ] || fail 'golden MANIFEST lost its zlib template line'
file_has_line "$md" "template commit: $tpl"
file_has_line "$md" 'void master: 665530c3d320'
file_has_line "$md" 'repodata slice: 18fbc0dcf949'
file_has_line "$md" 'run: RUN_URL'
file_matches "$md" '^reason-hash: [0-9a-f]\{64\}$'
file_has "$md" 'Fix the translator, never the recipe'
# holdback: the staged diff is the report alone; zlib's recipe rides
# untouched and stays out of provided.suggested
staged=$(git -C "$TMPD/repo" diff --cached --name-only)
assert_eq "$staged" report 'a held day stages the report and nothing else'
grep -q '^zlib' "$TMPD/repo/provided.suggested" \
    && fail 'a held package leaked into provided.suggested'
file_has "$TMPD/repo/report" 'refused: zlib'
assert_eq "$(sha256sum "$TMPD/repo/recipes/hand1/build" \
    "$TMPD/repo/recipes/hand1/meta")" "$hand0" \
    'handwritten recipe must ride the regeneration untouched'

# --- apply: the report commit pushes, one issue create. Invoked with
#     RELATIVE paths, the workflow's shape: git -C would resolve a
#     relative commit -F inside the checkout (the first live push
#     failed exactly there), so apply must pin its paths absolute ---
head0=$(git -C "$TMPD/repo.git" rev-parse refs/heads/main)
apply_abs=$PWD/ci/repo-apply.sh
run sh -c 'cd "$1" && sh "$2" --decisions dec --repo repo \
    --issue-repo alperien/chy --gh "$1/bin/gh"' apply "$TMPD" "$apply_abs"
assert_rc 0 'apply on a held day'
[ "$(git -C "$TMPD/repo.git" rev-parse refs/heads/main)" != "$head0" ] \
    || fail 'the held-day report commit did not push'
assert_eq "$(count_matches '^issue create ' "$TMPD/gh.log")" 1 'one issue create'
file_matches "$TMPD/gh.log" \
    '^issue create --repo alperien/chy --title repo-sync: refused: zlib '
assert_eq "$(count_matches '^issue \(comment\|close\|edit\) ' "$TMPD/gh.log")" 0 \
    'no comments, closes, or edits'

# --- sync 2: the identical day after. Nothing moves: unchanged, and
#     the refusal is still an issue decision ---
run sh ci/repo-sync.sh --snapshot "$TMPD/snap" --repo "$TMPD/repo" \
    --set "$g/names" --decisions "$TMPD/dec2" --translator translator
assert_rc 0 'sync on the identical held day'
assert_eq "$(cat "$TMPD/dec2/nochange")" unchanged 'nochange verdict'
assert_absent "$TMPD/dec2/commit.msg"
[ -f "$TMPD/dec2/issues/refused-zlib.md" ] || fail 'refusal re-decided on the identical day'
[ -z "$(git -C "$TMPD/repo" status --porcelain)" ] \
    || fail 'an unchanged held day dirtied the repo checkout'

# --- sync 3: the refusal plus a stale recipe and a ghost set name;
#     the diff commits, zlib holds, the ghost stays absent ---
printf '0.0 1\n' >"$TMPD/repo/recipes/expat/version"   # the staleness
git -C "$TMPD/repo" -c user.name=seed -c user.email=seed@test \
    commit -qam 'seed: stale expat'
git -C "$TMPD/repo" push -q origin HEAD:main
{ cat "$g/names"; printf 'ghost\n'; } >"$TMPD/names"

run sh ci/repo-sync.sh --snapshot "$TMPD/snap" --repo "$TMPD/repo" \
    --set "$TMPD/names" --decisions "$TMPD/dec3" --translator translator
assert_rc 0 'sync decides on a held-plus-changed day'
[ -f "$TMPD/dec3/commit.msg" ] || fail 'holdback must not block the day'
file_has "$TMPD/dec3/commit.msg" 'refused 2'
file_has_line "$TMPD/dec3/issues/refused-ghost.md" \
    'state: absent (no prior recipe to hold)'
assert_eq "$(find "$TMPD/dec3/issues" -type f | wc -l)" 2 'two issue decisions'
git -C "$TMPD/repo" diff --cached --name-only | grep -q '^recipes/expat/' \
    || fail 'stale expat missing from the staged diff'
git -C "$TMPD/repo" diff --cached --name-only | grep -q '^recipes/zlib/' \
    && fail 'held zlib leaked into the staged diff'
assert_absent "$TMPD/repo/recipes/ghost"

# --- coda: no snapshot at all is the infra decision, still no commit ---
run sh ci/repo-sync.sh --snapshot "$TMPD/gone" --repo "$TMPD/repo" \
    --set "$g/names" --decisions "$TMPD/dec4" --translator translator
assert_rc 0 'sync decides on an infra failure'
assert_eq "$(cat "$TMPD/dec4/nochange")" infra 'nochange verdict'
assert_absent "$TMPD/dec4/commit.msg"
file_has "$TMPD/dec4/issues/infra.md" 'not a snapshot'
file_matches "$TMPD/dec4/issues/infra.md" '^reason-hash: [0-9a-f]\{64\}$'

exit 0
