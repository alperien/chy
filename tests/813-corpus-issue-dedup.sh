#!/bin/sh
# 813: refusal issue dedup by title and reason-hash.
#
# Same sabotaged snapshot as 812; the stub gh (found via PATH here, no
# --gh, exercising corpus-apply.sh's default) serves a canned issue list
# that already shows `corpus-sync: refused: zlib` open. A matching
# reason-hash marker means silence: no create, no comment. A different
# hash means exactly one comment, plus the body refresh that keeps the
# marker tracking the live reason.
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

cp -R "$g/snapshot" "$TMPD/snap"
printf 'build_style=waf\n' >>"$TMPD/snap/srcpkgs/zlib/template"

git init -q --bare "$TMPD/corpus.git"
git -C "$TMPD/corpus.git" symbolic-ref HEAD refs/heads/main
git clone -q "$TMPD/corpus.git" "$TMPD/corpus" 2>/dev/null
git -C "$TMPD/corpus" symbolic-ref HEAD refs/heads/main
cp -R "$g/expected/recipes" "$TMPD/corpus/recipes"
for f in shlibs.map provided.suggested report TRANSLATOR_VERSION; do
    cp "$g/expected/$f" "$TMPD/corpus/$f"
done
printf 'chy corpus (generated)\n' >"$TMPD/corpus/README.md"
chmod 755 "$TMPD/corpus"/recipes/*/build
git -C "$TMPD/corpus" add -A
git -C "$TMPD/corpus" -c user.name=seed -c user.email=seed@test \
    commit -qm 'seed: golden corpus'
git -C "$TMPD/corpus" push -q origin HEAD:main

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

run sh ci/corpus-sync.sh --snapshot "$TMPD/snap" --corpus "$TMPD/corpus" \
    --set "$g/names" --decisions "$TMPD/dec" --translator translator
assert_rc 0 'sync on the sabotaged snapshot'
md="$TMPD/dec/issues/refused-zlib.md"
[ -f "$md" ] || fail 'issues/refused-zlib.md missing'
hash=$(sed -n 's/^reason-hash: //p' "$md" | head -n 1)
[ -n "$hash" ] || fail 'decision carries no reason-hash'

# --- already open, same reason-hash: dead silence ---
printf '[{"number":7,"title":"corpus-sync: refused: zlib","body":"reason-hash: %s"}]\n' \
    "$hash" >"$TMPD/issues.json"
run env PATH="$TMPD/bin:$PATH" sh ci/corpus-apply.sh --decisions "$TMPD/dec" \
    --corpus "$TMPD/corpus" --issue-repo alperien/chy
assert_rc 0 'apply against a matching open issue'
file_has_line "$OUT" 'corpus-apply: already open, reason unchanged: corpus-sync: refused: zlib'
assert_eq "$(count_matches '^issue list ' "$TMPD/gh.log")" 1 'one issue listing'
assert_eq "$(count_matches '^issue \(create\|comment\|close\|edit\) ' "$TMPD/gh.log")" 0 \
    'silence when the reason is unchanged'

# --- already open, different reason-hash: one comment, body refreshed ---
: >"$TMPD/gh.log"
printf '[{"number":7,"title":"corpus-sync: refused: zlib","body":"reason-hash: %s"}]\n' \
    "$(printf '%064d' 0)" >"$TMPD/issues.json"
run env PATH="$TMPD/bin:$PATH" sh ci/corpus-apply.sh --decisions "$TMPD/dec" \
    --corpus "$TMPD/corpus" --issue-repo alperien/chy
assert_rc 0 'apply against a stale open issue'
assert_eq "$(count_matches '^issue comment 7 ' "$TMPD/gh.log")" 1 'exactly one comment'
assert_eq "$(count_matches '^issue edit 7 ' "$TMPD/gh.log")" 1 'one body refresh'
assert_eq "$(count_matches '^issue \(create\|close\) ' "$TMPD/gh.log")" 0 \
    'no create, no close'

exit 0
