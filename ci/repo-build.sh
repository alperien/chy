#!/bin/sh
# ci/repo-build.sh - the build gate over a staged sync (between steps
# 4 and 5).
#
# repo-sync.sh stages the day's diff and prepares commit.msg; this
# gate proves the staged recipes actually build before repo-apply.sh
# is allowed to push. Scope is exactly the recipes the staged diff
# touches: each is installed through chy itself into a throwaway
# root, so its dependency closure builds as needed and host packages
# come from db/provided (seeded from the repo's own
# provided.suggested). A failure writes issues/build-<name>.md, drops
# commit.msg, and records the build-failed verdict: the all-or-nothing
# rule extends to builds, so a day the gate rejects commits nothing.
#
#   repo-build.sh --repo DIR --decisions DIR [--chy FILE] [--root DIR]
#
# --root is a prepared build root (the tests seed its cache/); by
# default a temporary one is created and removed. Exit 0 means the
# decision stands or was rewritten to build-failed; any other exit is
# the gate itself breaking, which the workflow treats as infra.
set -eu

say() { printf 'repo-build: %s\n' "$1"; }
die() { printf 'repo-build: error: %s\n' "$1" >&2; exit 1; }

hash_of() { # STRING - the reason-hash dedup marker value
    printf '%s\n' "$1" | sha256sum | cut -d ' ' -f 1
}

repo='' decisions='' chy=chy/chy root=''
while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || die "$1 needs a value"
    case $1 in
        --repo)      repo=$2 ;;
        --decisions) decisions=$2 ;;
        --chy)       chy=$2 ;;
        --root)      root=$2 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift 2
done
if [ -z "$repo" ] || [ -z "$decisions" ]; then
    die 'usage: --repo DIR --decisions DIR [--chy FILE] [--root DIR]'
fi
[ -f "$chy" ] || die "no chy at $chy"
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 \
    || die "not a git checkout: $repo"

if [ ! -f "$decisions/commit.msg" ]; then
    say 'no commit staged, nothing to build'
    exit 0
fi

# the recipes this sync touches: first path component under recipes/
# in the staged diff. A name gone from the worktree is a prune and
# has nothing to build.
names=$(git -C "$repo" diff --cached --name-only -- recipes/ \
    | sed -n 's|^recipes/\([^/][^/]*\)/.*|\1|p' | LC_ALL=C sort -u)
if [ -z "$names" ]; then
    say 'no recipe changes staged, nothing to build'
    exit 0
fi

scratch=''
if [ -z "$root" ]; then
    scratch=$(mktemp -d) || die 'mktemp -d failed'
    trap 'rm -rf "$scratch"' EXIT INT TERM
    root="$scratch/root"
fi
mkdir -p "$root/db"
repo_abs=$(cd "$repo" && pwd)
[ -e "$root/recipes" ] || ln -s "$repo_abs/recipes" "$root/recipes"
if [ -f "$repo/shlibs.map" ] && [ ! -f "$root/shlibs.map" ]; then
    cp "$repo/shlibs.map" "$root/shlibs.map"
fi
# host-provided names: the first column of the repo's own suggestions
if [ -f "$repo/provided.suggested" ] && [ ! -f "$root/db/provided" ]; then
    awk 'NF {print $1}' "$repo/provided.suggested" >"$root/db/provided"
fi

built=0 failed=''
while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ ! -d "$repo/recipes/$name" ]; then
        say "pruned, not built: $name"
        continue
    fi
    log="${scratch:-${TMPDIR:-/tmp}}/build-$name.log"
    if CHY_ROOT="$root" sh "$chy" install "$name" >"$log" 2>&1; then
        built=$((built + 1))
        say "built: $name"
        rm -f "$log"
        continue
    fi
    failed="$failed$name "
    say "build FAILED: $name"
    # the tail goes to the step log too: on a dry run the issue file
    # below is never filed, and a rejection nobody can read is noise
    tail -n 15 "$log" 2>/dev/null | sed 's/^/repo-build:   /'
    last=$(tail -n 1 "$log" 2>/dev/null) || last=''
    mkdir -p "$decisions/issues"
    {
        printf 'The build gate rejected the staged sync: %s failed to build.\n\n' "$name"
        printf 'package: %s\n' "$name"
        printf 'void commit: %s\n' "$(sed -n 's/^void-commit: //p' \
            "$repo/recipes/$name/meta" 2>/dev/null | head -n 1 | grep . \
            || printf 'unknown')"
        printf '\nlast 30 lines:\n\n```\n'
        tail -n 30 "$log" 2>/dev/null || true
        printf '```\n\n'
        printf 'Nothing was committed (all-or-nothing). Translated output is\n'
        printf 'regenerated wholesale, so fix the translator or its inputs,\n'
        printf 'never the recipe; this issue closes on the next push that\n'
        printf 'carries %s.\n\n' "$name"
        printf 'run: RUN_URL\n\n'
        printf 'reason-hash: %s\n' "$(hash_of "build $name: $last")"
    } >"$decisions/issues/build-$name.md"
    rm -f "$log"
done <<EOF
$names
EOF

if [ -n "$failed" ]; then
    rm -f "$decisions/commit.msg"
    printf 'build-failed\n' >"$decisions/nochange"
    say "rejected: $failed- no commit (all-or-nothing)"
    exit 0
fi
say "$built recipe(s) built clean, decision stands"
exit 0
