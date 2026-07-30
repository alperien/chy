#!/bin/sh
# 812: refusal is an issue decision, never a commit.
#
# A copy of the golden snapshot gets one sabotaged template: appending
# build_style=waf (outside the allowlist) makes zlib a
# guaranteed refusal while the other nineteen translate. All-or-nothing:
# repo-sync.sh must write issues/refused-zlib.md (verbatim reason,
# pinned template commit, reason-hash) and no commit.msg, leaving the
# checkout pristine; repo-apply.sh must log exactly one issue create
# and push nothing. Coda: a missing snapshot is the infra decision.
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
for f in shlibs.map provided.suggested report TRANSLATOR_VERSION; do
    cp "$g/expected/$f" "$TMPD/repo/$f"
done
printf 'chy default repo (generated)\n' >"$TMPD/repo/README.md"
chmod 755 "$TMPD/repo"/recipes/*/build
git -C "$TMPD/repo" add -A
git -C "$TMPD/repo" -c user.name=seed -c user.email=seed@test \
    commit -qm 'seed: golden repo'
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

# --- sync: refusal path, one issue decision, commit nothing ---
run sh ci/repo-sync.sh --snapshot "$TMPD/snap" --repo "$TMPD/repo" \
    --set "$g/names" --decisions "$TMPD/dec" --translator translator
assert_rc 0 'sync decides, it does not fail, on a refusal'
assert_eq "$(cat "$TMPD/dec/nochange")" refused 'nochange verdict'
assert_absent "$TMPD/dec/commit.msg"
md="$TMPD/dec/issues/refused-zlib.md"
[ -f "$md" ] || fail 'issues/refused-zlib.md missing'
assert_eq "$(find "$TMPD/dec/issues" -type f | wc -l)" 1 'exactly one issue decision'
# the verbatim reason (TRANSLATOR emit wording), body fields
file_has "$md" "refused: zlib: build_style 'waf' is outside the allowlist"
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
# all-or-nothing: the nineteen good translations must not reach the repo
[ -z "$(git -C "$TMPD/repo" status --porcelain)" ] \
    || fail 'a refusal dirtied the repo checkout'

# --- apply: exactly one issue create, no push ---
head0=$(git -C "$TMPD/repo.git" rev-parse refs/heads/main)
run sh ci/repo-apply.sh --decisions "$TMPD/dec" --repo "$TMPD/repo" \
    --issue-repo alperien/chy --gh "$TMPD/bin/gh"
assert_rc 0 'apply on a refusal verdict'
assert_eq "$(git -C "$TMPD/repo.git" rev-parse refs/heads/main)" "$head0" \
    'bare HEAD moved on a refusal'
assert_eq "$(count_matches '^issue create ' "$TMPD/gh.log")" 1 'one issue create'
file_matches "$TMPD/gh.log" \
    '^issue create --repo alperien/chy --title repo-sync: refused: zlib '
assert_eq "$(count_matches '^issue \(comment\|close\|edit\) ' "$TMPD/gh.log")" 0 \
    'no comments, closes, or edits'

# --- coda: no snapshot at all is the infra decision, still no commit ---
run sh ci/repo-sync.sh --snapshot "$TMPD/gone" --repo "$TMPD/repo" \
    --set "$g/names" --decisions "$TMPD/dec2" --translator translator
assert_rc 0 'sync decides on an infra failure'
assert_eq "$(cat "$TMPD/dec2/nochange")" infra 'nochange verdict'
assert_absent "$TMPD/dec2/commit.msg"
file_has "$TMPD/dec2/issues/infra.md" 'not a snapshot'
file_matches "$TMPD/dec2/issues/infra.md" '^reason-hash: [0-9a-f]\{64\}$'
[ -z "$(git -C "$TMPD/repo" status --porcelain)" ] \
    || fail 'an infra failure dirtied the repo checkout'

exit 0
