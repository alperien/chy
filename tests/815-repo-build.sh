#!/bin/sh
# 815: the build gate over a staged sync (ci/repo-build.sh).
#
# A local git checkout plays the staged recipe repo, with script-only
# recipes in the lib.sh shape (cached seed, unreachable URL), so the
# builds run anywhere without a toolchain. Under test: nothing staged
# is a fast pass; staged changes build through chy into a prepared
# root and the decision stands; a failing build drops commit.msg,
# records the build-failed verdict, writes issues/build-<name>.md
# with a reason-hash, and the other staged names are still attempted;
# a pruned recipe is skipped; repo-apply.sh files the build issue by
# title and pushes nothing.
set -eu
cd "$(dirname "$0")/.." || exit 2
# shellcheck source=tests/lib.sh disable=SC1091
. ./tests/lib.sh

for t in git python3; do
    command -v "$t" >/dev/null 2>&1 || { echo "SKIP: $t unavailable"; exit 0; }
done

t_init

# --- the staged repo checkout: recipes come from a scratch root so
#     mkpkg's cache seeds stay behind for the build roots ---
seedroot="$TMPD/seedroot"
repo="$TMPD/repo"
git init -q "$repo"
git -C "$repo" symbolic-ref HEAD refs/heads/main
mkdir -p "$repo/recipes"

mkpkg "$seedroot" toyok '1.0 1' usr/toyok.txt
mkpkg "$seedroot" toygone '1.0 1' usr/toygone.txt
mv "$seedroot/recipes/toyok" "$repo/recipes/toyok"
mv "$seedroot/recipes/toygone" "$repo/recipes/toygone"
: >"$repo/provided.suggested"
: >"$repo/shlibs.map"
git -C "$repo" add -A
git -C "$repo" -c user.name=seed -c user.email=seed@test \
    commit -qm 'seed: prior repo state'

# --- nothing staged, nothing decided: the gate passes through ---
mkdir -p "$TMPD/dec0"
run sh ci/repo-build.sh --repo "$repo" --decisions "$TMPD/dec0"
assert_rc 0 'gate without a staged commit'
file_has "$OUT" 'no commit staged'

# --- a clean day: one bump, one prune, decision stands ---
mkpkg "$seedroot" toyok '1.1 1' usr/toyok.txt
rm -rf "$repo/recipes/toyok"
mv "$seedroot/recipes/toyok" "$repo/recipes/toyok"
git -C "$repo" rm -r -q recipes/toygone
git -C "$repo" add -A
mkdir -p "$TMPD/dec1"
printf 'test commit\n' >"$TMPD/dec1/commit.msg"
broot1="$TMPD/broot1"
mkdir -p "$broot1/cache"
cp "$seedroot/cache/"* "$broot1/cache/"

run sh ci/repo-build.sh --repo "$repo" --decisions "$TMPD/dec1" \
    --root "$broot1"
assert_rc 0 'gate on a clean staged day'
file_has "$OUT" 'built: toyok'
file_has "$OUT" 'pruned, not built: toygone'
file_has "$OUT" 'decision stands'
[ -f "$TMPD/dec1/commit.msg" ] || fail 'clean gate ate commit.msg'
assert_absent "$TMPD/dec1/issues"
assert_installed "$broot1" toyok 1.1 1

# --- a failing build: verdict rewritten, the rest still attempted ---
mkpkg "$seedroot" toybad '1.0 1'
# a build script that reads stdin must never see the gate's name
# queue; the gate closes stdin off as defense in depth (today chy's
# own driver also shields it, but the gate must not depend on that)
printf 'set -eu\nread -r eaten || true\necho doomed-build-marker >&2\nexit 7\n' \
    >"$seedroot/recipes/toybad/build"
mv "$seedroot/recipes/toybad" "$repo/recipes/toybad"
mkpkg "$seedroot" toyok '1.2 1' usr/toyok.txt
rm -rf "$repo/recipes/toyok"
mv "$seedroot/recipes/toyok" "$repo/recipes/toyok"
git -C "$repo" add -A
mkdir -p "$TMPD/dec2"
printf 'test commit\n' >"$TMPD/dec2/commit.msg"
broot2="$TMPD/broot2"
mkdir -p "$broot2/cache"
cp "$seedroot/cache/"* "$broot2/cache/"

run sh ci/repo-build.sh --repo "$repo" --decisions "$TMPD/dec2" \
    --root "$broot2"
assert_rc 0 'gate on a failing day still decides'
file_has "$OUT" 'build FAILED: toybad'
file_has "$OUT" 'doomed-build-marker'
file_has "$OUT" 'built: toyok'
file_has "$OUT" 'no commit (all-or-nothing)'
assert_absent "$TMPD/dec2/commit.msg"
assert_eq "$(cat "$TMPD/dec2/nochange")" build-failed 'nochange verdict'
file_has "$TMPD/dec2/issues/build-toybad.md" 'package: toybad'
file_matches "$TMPD/dec2/issues/build-toybad.md" \
    '^reason-hash: [0-9a-f]\{64\}$'
assert_absent "$TMPD/dec2/issues/build-toyok.md"

# --- apply files the build issue by title, pushes nothing ---
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

head0=$(git -C "$repo" rev-parse HEAD)
run sh ci/repo-apply.sh --decisions "$TMPD/dec2" --repo "$repo" \
    --issue-repo alperien/chy --gh "$TMPD/bin/gh"
assert_rc 0 'apply on a build-failed verdict'
file_has "$TMPD/gh.log" 'issue create'
file_has "$TMPD/gh.log" 'repo-sync: build failed: toybad'
assert_eq "$(git -C "$repo" rev-parse HEAD)" "$head0" \
    'apply must not commit on a build-failed day'

# --- warm-root reuse: reconcile removes what the staged repo no
#     longer vouches for, keeps clean deps unbuilt, and discards an
#     un-reconcilable root (keeping cache/) ---
git -C "$repo" -c user.name=seed -c user.email=seed@test \
    commit -qm 'baseline for reuse cases'

# day 1: toylib plus toyapp (depends toylib) plus toygone2
mkpkg "$seedroot" toylib '1.0 1' usr/lib/toylib.txt
printf 'printf x >>"%s"\n' "$TMPD/stamp-toylib" \
    >>"$seedroot/recipes/toylib/build"
mkpkg "$seedroot" toyapp '1.0 1' usr/bin/toyapp
recipe_list "$seedroot" toyapp depends toylib
mkpkg "$seedroot" toygone2 '1.0 1' usr/share/gone2.txt
for n in toylib toyapp toygone2; do
    rm -rf "$repo/recipes/$n"
    mv "$seedroot/recipes/$n" "$repo/recipes/$n"
done
git -C "$repo" add -A
mkdir -p "$TMPD/dec5"
printf 'test commit\n' >"$TMPD/dec5/commit.msg"
broot="$TMPD/broot-warm"
mkdir -p "$broot/cache"
cp "$seedroot/cache/"* "$broot/cache/"

run sh ci/repo-build.sh --repo "$repo" --decisions "$TMPD/dec5" \
    --root "$broot"
assert_rc 0 'warm-root day 1'
[ -f "$TMPD/dec5/commit.msg" ] || fail 'day 1 should stand'
assert_installed "$broot" toylib 1.0 1
assert_installed "$broot" toyapp 1.0 1
stamps1=$(wc -c <"$TMPD/stamp-toylib")

# day 2: bump toyapp, drop toygone2's recipe; toylib untouched
git -C "$repo" -c user.name=seed -c user.email=seed@test \
    commit -qm 'day 1 state'
mkpkg "$seedroot" toyapp '2.0 1' usr/bin/toyapp
recipe_list "$seedroot" toyapp depends toylib
rm -rf "$repo/recipes/toyapp"
mv "$seedroot/recipes/toyapp" "$repo/recipes/toyapp"
cp "$seedroot/cache/seed-toyapp.txt" "$broot/cache/"
git -C "$repo" rm -r -q recipes/toygone2
git -C "$repo" add -A
mkdir -p "$TMPD/dec6"
printf 'test commit\n' >"$TMPD/dec6/commit.msg"

run sh ci/repo-build.sh --repo "$repo" --decisions "$TMPD/dec6" \
    --root "$broot"
assert_rc 0 'warm-root day 2'
[ -f "$TMPD/dec6/commit.msg" ] || fail 'day 2 should stand'
assert_installed "$broot" toyapp 2.0 1
assert_not_installed "$broot" toygone2
assert_eq "$(wc -c <"$TMPD/stamp-toylib")" "$stamps1" \
    'an unchanged dependency must not rebuild on a warm root'

# day 3: bump toylib while installed toyapp still depends on it; the
# removal is vetoed, the root discards (cache kept), the diff builds
# fresh
git -C "$repo" -c user.name=seed -c user.email=seed@test \
    commit -qm 'day 2 state'
mkpkg "$seedroot" toylib '2.0 1' usr/lib/toylib.txt
printf 'printf x >>"%s"\n' "$TMPD/stamp-toylib" \
    >>"$seedroot/recipes/toylib/build"
rm -rf "$repo/recipes/toylib"
mv "$seedroot/recipes/toylib" "$repo/recipes/toylib"
cp "$seedroot/cache/seed-toylib.txt" "$broot/cache/"
git -C "$repo" add -A
mkdir -p "$TMPD/dec7"
printf 'test commit\n' >"$TMPD/dec7/commit.msg"

run sh ci/repo-build.sh --repo "$repo" --decisions "$TMPD/dec7" \
    --root "$broot"
assert_rc 0 'warm-root day 3'
file_has "$OUT" 'starting fresh'
[ -f "$TMPD/dec7/commit.msg" ] || fail 'day 3 should stand'
assert_installed "$broot" toylib 2.0 1
assert_not_installed "$broot" toyapp

exit 0
