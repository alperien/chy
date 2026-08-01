#!/bin/sh
# 815: the build gate over a staged sync (ci/repo-build.sh).
#
# A local git checkout plays the staged recipe repo, script-only
# recipes in the lib.sh shape (cached seed, unreachable URL), so the
# builds run anywhere without a toolchain. Covered: nothing staged is a
# fast pass; a clean day leaves the decision standing; a failing NEW
# name is held absent and the day still stands with a "gate held:"
# line; a failing dep cascades (the dependent over-holds by design) and
# round two validates the held pair; a held name that fails again
# unwinds its in-diff dependencies; a held name with nothing to unwind
# rejects the day; prunes are skipped; repo-apply pushes a held day,
# files its issues, and does NOT auto-close an issue whose hold is
# today's live state; warm roots reconcile (drift and recipe-gone
# entries leave, clean deps stay unbuilt, a vetoed removal discards
# the root but keeps cache/).
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
git init -q --bare "$TMPD/repo.git"
git -C "$TMPD/repo.git" symbolic-ref HEAD refs/heads/main
git -C "$repo" remote add origin "$TMPD/repo.git"
mkdir -p "$repo/recipes"

mkpkg "$seedroot" toyok '1.0 1' usr/toyok.txt
mkpkg "$seedroot" toygone '1.0 1' usr/toygone.txt
mv "$seedroot/recipes/toyok" "$repo/recipes/toyok"
mv "$seedroot/recipes/toygone" "$repo/recipes/toygone"
: >"$repo/provided.suggested"
: >"$repo/shlibs.map"
printf 'translated: toyok\ntranslated: toybad\n' >"$repo/report"
git -C "$repo" add -A
git -C "$repo" -c user.name=seed -c user.email=seed@test \
    commit -qm 'seed: prior repo state'
git -C "$repo" push -q origin HEAD:main

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

# --- a failing NEW name: held absent, the day stands ---
mkpkg "$seedroot" toybad '1.0 1'
# the read probes stdin isolation; the marker proves tails surface
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
assert_rc 0 'gate holds a failing new name'
file_has "$OUT" 'build FAILED: toybad'
file_has "$OUT" 'doomed-build-marker'
file_has "$OUT" 'held absent: toybad'
file_has "$OUT" 'built: toyok'
[ -f "$TMPD/dec2/commit.msg" ] || fail 'a held day must stand'
file_has "$TMPD/dec2/commit.msg" 'gate held: toybad'
file_has "$TMPD/dec2/issues/build-toybad.md" 'held'
file_matches "$TMPD/dec2/issues/build-toybad.md" \
    '^reason-hash: [0-9a-f]\{64\}$'
assert_absent "$repo/recipes/toybad"
git -C "$repo" diff --cached --name-only | grep -q toybad \
    && fail 'held-absent name leaked into the staged diff'

# --- apply pushes the held day, files the issue, and does not
#     auto-close it even though the report says translated ---
printf '[{"number":9,"title":"repo-sync: build failed: toybad","body":"reason-hash: 0"}]\n' \
    >"$TMPD/issues.json"
mkdir -p "$TMPD/bin"
: >"$TMPD/gh.log"
cat >"$TMPD/bin/gh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$TMPD/gh.log"
case "\$1 \${2:-}" in
    'issue list') cat "$TMPD/issues.json" ;;
esac
EOF
chmod 755 "$TMPD/bin/gh"
head0=$(git -C "$TMPD/repo.git" rev-parse refs/heads/main)
run sh ci/repo-apply.sh --decisions "$TMPD/dec2" --repo "$repo" \
    --issue-repo alperien/chy --gh "$TMPD/bin/gh"
assert_rc 0 'apply on a held day'
[ "$(git -C "$TMPD/repo.git" rev-parse refs/heads/main)" != "$head0" ] \
    || fail 'a held day must push'
assert_eq "$(count_matches '^issue close ' "$TMPD/gh.log")" 0 \
    'a live hold must not auto-close'
assert_eq "$(count_matches '^issue \(comment\|edit\) 9 ' "$TMPD/gh.log")" 2 \
    'the hold issue refreshes its reason'

# --- a failing DEP cascades and round two validates the held pair ---
mkpkg "$seedroot" toydep '1.0 1' usr/lib/toydep.txt
mkpkg "$seedroot" toyuser '1.0 1' usr/bin/toyuser
recipe_list "$seedroot" toyuser depends toydep
for n in toydep toyuser; do
    rm -rf "$repo/recipes/$n"
    mv "$seedroot/recipes/$n" "$repo/recipes/$n"
done
git -C "$repo" add -A
git -C "$repo" -c user.name=seed -c user.email=seed@test \
    commit -qm 'baseline with toydep and toyuser'
mkpkg "$seedroot" toydep '2.0 1' usr/lib/toydep.txt
printf 'set -eu\nexit 9\n' >"$seedroot/recipes/toydep/build"
mkpkg "$seedroot" toyuser '2.0 1' usr/bin/toyuser
recipe_list "$seedroot" toyuser depends toydep
for n in toydep toyuser; do
    rm -rf "$repo/recipes/$n"
    mv "$seedroot/recipes/$n" "$repo/recipes/$n"
done
git -C "$repo" add -A
mkdir -p "$TMPD/dec3"
printf 'test commit\n' >"$TMPD/dec3/commit.msg"
broot3="$TMPD/broot3"
mkdir -p "$broot3/cache"
cp "$seedroot/cache/"* "$broot3/cache/"

run sh ci/repo-build.sh --repo "$repo" --decisions "$TMPD/dec3" \
    --root "$broot3"
assert_rc 0 'gate on a failing dep'
file_has "$OUT" 'build FAILED: toydep'
file_has "$OUT" 'round 2'
[ -f "$TMPD/dec3/commit.msg" ] || fail 'the cascade day must stand'
file_has "$TMPD/dec3/commit.msg" 'gate held:'
file_has "$TMPD/dec3/commit.msg" 'toydep'
assert_eq "$(head -n 1 "$repo/recipes/toydep/version")" '1.0 1' \
    'held dep restored to HEAD'
# the cascade over-holds the dependent by design; both live in HEAD
assert_eq "$(head -n 1 "$repo/recipes/toyuser/version")" '1.0 1' \
    'cascaded dependent restored to HEAD'

# --- a held name that fails against the survivors unwinds its
#     in-diff dependency; round three validates the held pair ---
git -C "$repo" -c user.name=seed -c user.email=seed@test \
    commit -qm 'post-cascade baseline' >/dev/null 2>&1 || true
mkpkg "$seedroot" libx '1.0 1' usr/lib/libx.txt
cat >"$seedroot/recipes/libx/build" <<'EOF'
set -eu
mkdir -p "$1$CHY_ROOT/usr/lib"
printf 'v1\n' >"$1$CHY_ROOT/usr/lib/libx.txt"
EOF
mkpkg "$seedroot" tooly '1.0 1' usr/bin/tooly
recipe_list "$seedroot" tooly depends libx
cat >"$seedroot/recipes/tooly/build" <<'EOF'
set -eu
grep -qx v1 "$CHY_ROOT/usr/lib/libx.txt"
mkdir -p "$1$CHY_ROOT/usr/bin"
printf 'ok\n' >"$1$CHY_ROOT/usr/bin/tooly"
EOF
for n in libx tooly; do
    rm -rf "$repo/recipes/$n"
    mv "$seedroot/recipes/$n" "$repo/recipes/$n"
done
git -C "$repo" add -A
git -C "$repo" -c user.name=seed -c user.email=seed@test \
    commit -qm 'baseline with libx v1 and tooly needing v1'
# the day: libx v2 (fine) plus tooly v2 (always broken)
mkpkg "$seedroot" libx '2.0 1' usr/lib/libx.txt
cat >"$seedroot/recipes/libx/build" <<'EOF'
set -eu
mkdir -p "$1$CHY_ROOT/usr/lib"
printf 'v2\n' >"$1$CHY_ROOT/usr/lib/libx.txt"
EOF
mkpkg "$seedroot" tooly '2.0 1' usr/bin/tooly
recipe_list "$seedroot" tooly depends libx
printf 'set -eu\nexit 3\n' >"$seedroot/recipes/tooly/build"
for n in libx tooly; do
    rm -rf "$repo/recipes/$n"
    mv "$seedroot/recipes/$n" "$repo/recipes/$n"
done
git -C "$repo" add -A
mkdir -p "$TMPD/dec4"
printf 'test commit\n' >"$TMPD/dec4/commit.msg"
broot4="$TMPD/broot4"
mkdir -p "$broot4/cache"
cp "$seedroot/cache/"* "$broot4/cache/"

run sh ci/repo-build.sh --repo "$repo" --decisions "$TMPD/dec4" \
    --root "$broot4"
assert_rc 0 'gate on a held name failing against the survivors'
file_has "$OUT" 'held (unwound under tooly): libx'
file_has "$OUT" 'round 3'
[ -f "$TMPD/dec4/commit.msg" ] || fail 'the unwind day must stand'
file_has "$TMPD/dec4/commit.msg" 'gate held:'
assert_eq "$(head -n 1 "$repo/recipes/libx/version")" '1.0 1' \
    'unwound dep restored to HEAD'
assert_eq "$(head -n 1 "$repo/recipes/tooly/version")" '1.0 1' \
    'held name stays at HEAD'

# --- a held name with nothing to unwind rejects the day ---
git -C "$repo" -c user.name=seed -c user.email=seed@test \
    commit -qm 'post-unwind baseline' >/dev/null 2>&1 || true
mkpkg "$seedroot" toyloner '1.0 1' usr/bin/toyloner
printf 'set -eu\nexit 5\n' >"$seedroot/recipes/toyloner/build"
rm -rf "$repo/recipes/toyloner"
mv "$seedroot/recipes/toyloner" "$repo/recipes/toyloner"
git -C "$repo" add -A
git -C "$repo" -c user.name=seed -c user.email=seed@test \
    commit -qm 'baseline with a broken loner'
mkpkg "$seedroot" toyloner '2.0 1' usr/bin/toyloner
printf 'set -eu\nexit 5\n' >"$seedroot/recipes/toyloner/build"
rm -rf "$repo/recipes/toyloner"
mv "$seedroot/recipes/toyloner" "$repo/recipes/toyloner"
git -C "$repo" add -A
mkdir -p "$TMPD/dec8"
printf 'test commit\n' >"$TMPD/dec8/commit.msg"
broot8="$TMPD/broot8"
mkdir -p "$broot8/cache"
cp "$seedroot/cache/"* "$broot8/cache/"

run sh ci/repo-build.sh --repo "$repo" --decisions "$TMPD/dec8" \
    --root "$broot8"
assert_rc 0 'gate decides on an unwindable failure'
file_has "$OUT" 'nothing left to unwind'
assert_absent "$TMPD/dec8/commit.msg"
assert_eq "$(cat "$TMPD/dec8/nochange")" build-failed 'nochange verdict'

# --- warm-root reuse: reconcile removes what the staged repo no
#     longer vouches for, keeps clean deps unbuilt, and discards an
#     un-reconcilable root (keeping cache/) ---
git -C "$repo" checkout -q -- . 2>/dev/null || true
git -C "$repo" reset -q --hard HEAD
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

# --- doctor gates the day: a root whose installed files went missing
#     rejects after an otherwise clean build ---
git -C "$repo" -c user.name=seed -c user.email=seed@test \
    commit -qm 'day 3 state' >/dev/null 2>&1 || true
rm -f "$broot/usr/lib/toylib.txt"
mkpkg "$seedroot" toyapp '3.0 1' usr/bin/toyapp
recipe_list "$seedroot" toyapp depends toylib
rm -rf "$repo/recipes/toyapp"
mv "$seedroot/recipes/toyapp" "$repo/recipes/toyapp"
cp "$seedroot/cache/seed-toyapp.txt" "$broot/cache/"
git -C "$repo" add -A
mkdir -p "$TMPD/dec9"
printf 'test commit\n' >"$TMPD/dec9/commit.msg"

run sh ci/repo-build.sh --repo "$repo" --decisions "$TMPD/dec9" \
    --root "$broot"
assert_rc 0 'gate decides on a doctor finding'
file_has "$OUT" 'doctor found problems'
assert_absent "$TMPD/dec9/commit.msg"
assert_eq "$(cat "$TMPD/dec9/nochange")" doctor-failed 'nochange verdict'
file_has "$TMPD/dec9/issues/doctor.md" 'missing'
file_matches "$TMPD/dec9/issues/doctor.md" '^reason-hash: [0-9a-f]\{64\}$'

exit 0
